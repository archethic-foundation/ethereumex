defmodule Ethereumex.Client.BaseWSClient do
  @moduledoc """
  The Base Client exposes the Ethereum Client RPC functionality.

  We use a macro so that exposed functions can be used in different behaviours
  (HTTP or IPC).
  """

  alias Ethereumex.Client.WebSocketBehaviour
  alias Ethereumex.Counter

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour WebSocketBehaviour
      @type error :: WebSocketBehaviour.error()

      @impl true
      def eth_subscribe(event, params, opts \\ [])
      def eth_subscribe(event, nil, opts), do: request("eth_subscribe", [event], opts)
      def eth_subscribe(event, params, opts), do: request("eth_subscribe", [event, params], opts)

      @impl true
      def eth_unsubscribe(subscription_id, opts \\ []),
        do: request("eth_subscribe", [subscription_id], opts)

      @spec add_request_info(binary, [boolean() | binary | map | [binary]]) :: map
      defp add_request_info(method_name, params \\ []) do
        %{}
        |> Map.put("method", method_name)
        |> Map.put("jsonrpc", "2.0")
        |> Map.put("params", params)
      end

      @impl true
      def request(_name, _params, batch: true, url: _url),
        do: raise("Cannot use batch and url options at the same time")

      def request(name, params, batch: true) do
        name |> add_request_info(params)
      end

      def request(name, params, opts) do
        name
        |> add_request_info(params)
        |> server_request(opts)
      end

      @impl true
      def batch_request(methods, opts \\ []) do
        methods
        |> Enum.map(fn {method, params} ->
          opts = [batch: true]
          params = params ++ [opts]

          apply(__MODULE__, method, params)
        end)
        |> server_request(opts)
      end

      @impl true
      def single_request(payload, opts \\ []) do
        payload |> post_request(opts)
      end

      @spec format_batch([map()]) :: [{:ok, map() | nil | binary()} | {:error, any}]
      def format_batch(list) do
        list
        |> Enum.sort(fn %{"id" => id1}, %{"id" => id2} -> id1 <= id2 end)
        |> Enum.map(fn
          %{"result" => result} -> {:ok, result}
          %{"error" => error} -> {:error, error}
          other -> {:error, other}
        end)
      end

      defp post_request(payload, opts) do
        {:error, :not_implemented}
      end

      # The function that a behavior like HTTP or IPC needs to implement.
      defoverridable post_request: 2

      @spec server_request(list(map()) | map(), list()) :: {:ok, [any()]} | {:ok, any()} | error
      defp server_request(params, opts \\ []) do
        params
        |> prepare_request
        |> request(opts)
      end

      defp prepare_request(params) when is_list(params) do
        id = Counter.get(:rpc_counter)

        params =
          params
          |> Enum.with_index(1)
          |> Enum.map(fn {req_data, index} ->
            Map.put(req_data, "id", index + id)
          end)

        _ = Counter.increment(:rpc_counter, Enum.count(params), "eth_batch")

        params
      end

      defp prepare_request(params),
        do: Map.put(params, "id", Counter.increment(:rpc_counter, params["method"]))

      defp request(params, opts) do
        __MODULE__.single_request(params, opts)
      end
    end
  end
end
