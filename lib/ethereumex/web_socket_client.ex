defmodule Ethereumex.WebSocketClient do
  @moduledoc false

  use Ethereumex.Client.BaseWSClient
  use GenServer

  alias Ethereumex.Config
  alias Ethereumex.WebSocketRegistry
  alias Ethereumex.WebSocketSupervisor

  defstruct [
    :url,
    :parent_pid,
    :format_batch,
    :conn,
    :websocket,
    :request_ref,
    :caller,
    :status,
    :resp_headers,
    :closing?
  ]

  require Logger

  @type empty_response :: :empty_response
  @type invalid_json :: {:invalid_json, any()}
  @type http_client_error :: {:error, empty_response() | invalid_json() | any()}

  @spec post_request(map(), Keyword.t()) :: {:ok, any()} | http_client_error()
  def post_request(payload, opts) do
    headers = headers(opts)
    url = Keyword.get(opts, :url) || Config.rpc_url()

    format_batch =
      case Keyword.get(opts, :format_batch) do
        nil -> Config.format_batch()
        value -> value
      end

    with {:ok, pid} <- connect(url, format_batch, headers, self()),
         subscribe(pid, payload) do
      {:ok, pid}
    end
  end

  def subscribe(pid, payload) do
    GenServer.call(pid, {:subscribe, payload})
  end

  def start_link(opts) do
    [parent_pid: parent_pid, url: url] =
      Keyword.validate!(opts, [:parent_pid, :url]) |> Enum.sort()

    GenServer.start_link(__MODULE__, opts, name: via_tuple(parent_pid, url))
  end

  defp via_tuple(pid, url), do: {:via, Registry, {WebSocketRegistry, {pid, url}}}

  @impl GenServer
  def init(opts) do
    [format_batch: format_batch, parent_pid: parent_pid, url: url] =
      Keyword.validate!(opts, [:format_batch, :parent_pid, :url]) |> Enum.sort()

    {:ok, %__MODULE__{format_batch: format_batch, url: url, parent_pid: parent_pid}}
  end

  @impl GenServer
  def handle_call(:connect, from, %__MODULE__{url: url} = state) do
    %URI{host: host, port: port, scheme: scheme, query: query, path: path} = URI.parse(url)

    {http_scheme, ws_scheme} =
      case scheme do
        "ws" -> {:http, :ws}
        "wss" -> {:https, :wss}
      end

    path =
      case query do
        nil -> path
        query -> path <> "?" <> query
      end

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      state = %__MODULE__{state | conn: conn, request_ref: ref, caller: from}
      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, conn, reason} -> {:reply, {:error, reason}, %__MODULE__{state | conn: conn}}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, payload}, _from, state) do
    subscription_request_ids =
      case payload do
        subscriptions when is_list(subscriptions) ->
          Enum.map(subscriptions, &Map.fetch!(&1, "id"))

        %{"id" => id} ->
          [id]
      end

    {:ok, state} = send_frame(state, {:text, Jason.encode!(payload)})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(message, %__MODULE__{conn: conn} = state) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state =
          %__MODULE__{closing?: closing?} =
          %__MODULE__{state | conn: conn} |> handle_responses(responses)

        if closing? do
          # Streaming a close frame may fail if the server has already closed
          # for writing.
          _ = send_frame(state, :close)
          Mint.HTTP.close(state.conn)
          {:stop, :normal, state}
        else
          {:noreply, state}
        end

      {:error, conn, reason, _responses} ->
        state = %__MODULE__{state | conn: conn} |> reply({:error, reason})
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  defp headers(opts) do
    headers = Keyword.get(opts, :http_headers) || Config.http_headers()

    [{"Content-Type", "application/json"} | headers]
  end

  defp connect(url, format_batch, _headers, parent_pid) do
    child_spec = {__MODULE__, url: url, parent_pid: parent_pid, format_batch: format_batch}

    with {:ok, pid} <- DynamicSupervisor.start_child(WebSocketSupervisor, child_spec),
         {:ok, :connected} <- GenServer.call(pid, :connect) do
      {:ok, pid}
    else
      {:error, {:already_started, pid}} -> {:ok, pid}
      er -> er
    end
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = put_in(state.websocket, websocket),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, put_in(state.conn, conn)}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, put_in(state.websocket, websocket), reason}

      {:error, conn, reason} ->
        {:error, put_in(state.conn, conn), reason}
    end
  end

  defp handle_responses(state, []), do: state

  defp handle_responses(%__MODULE__{request_ref: ref} = state, [{:status, ref, status} | rest]) do
    %__MODULE__{state | status: status} |> handle_responses(rest)
  end

  defp handle_responses(%__MODULE__{request_ref: ref} = state, [
         {:headers, ref, resp_headers} | rest
       ]) do
    %__MODULE__{state | resp_headers: resp_headers} |> handle_responses(rest)
  end

  defp handle_responses(
         %__MODULE__{request_ref: ref, conn: conn, resp_headers: resp_headers} = state,
         [{:done, ref} | rest]
       ) do
    case Mint.WebSocket.new(conn, ref, state.status, resp_headers) do
      {:ok, conn, websocket} ->
        %__MODULE__{state | conn: conn, websocket: websocket, status: nil, resp_headers: nil}
        |> reply({:ok, :connected})
        |> handle_responses(rest)

      {:error, conn, reason} ->
        %__MODULE__{state | conn: conn} |> reply({:error, reason})
    end
  end

  defp handle_responses(%{request_ref: ref, websocket: websocket} = state, [
         {:data, ref, data} | rest
       ])
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        %__MODULE__{state | websocket: websocket}
        |> handle_frames(frames)
        |> handle_responses(rest)

      {:error, websocket, reason} ->
        %__MODULE__{state | websocket: websocket} |> reply({:error, reason})
    end
  end

  defp handle_responses(state, [_response | rest]), do: handle_responses(state, rest)

  defp handle_frames(state, frames) do
    Enum.reduce(frames, state, fn
      # reply to pings with pongs
      {:ping, data}, state ->
        {:ok, state} = send_frame(state, {:pong, data})
        state

      {:close, _code, reason}, state ->
        Logger.debug("Closing connection: #{inspect(reason)}")
        %__MODULE__{state | closing?: true}

      {:text, text}, %__MODULE__{format_batch: format_batch} = state ->
        decode_body(text, format_batch)
        state

      frame, state ->
        Logger.debug("Unexpected frame received: #{inspect(frame)}")
        state
    end)
  end

  defp decode_body(body, format_batch) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, result = [%{} | _]} ->
        {:ok, maybe_format_batch(result, format_batch)}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:error, %Jason.DecodeError{data: ""}} ->
        {:error, :empty_response}

      {:error, error} ->
        {:error, {:invalid_json, error}}
    end
  end

  defp maybe_format_batch(responses, true), do: format_batch(responses)
  defp maybe_format_batch(responses, _), do: responses

  defp reply(%__MODULE__{caller: nil} = state, _response), do: state

  defp reply(%__MODULE__{caller: caller} = state, response) do
    GenServer.reply(caller, response)
    %__MODULE__{state | caller: nil}
  end
end
