defmodule Ethereumex.Subscription do
  @moduledoc false

  @enforce_keys [:subscription_id, :connection_pid]
  defstruct [:subscription_id, :connection_pid, transport_opts: []]

  @type t :: %__MODULE__{
          subscription_id: String.t(),
          connection_pid: pid(),
          transport_opts: list()
        }

  @type event :: String.t()

  @type params :: map() | nil
end
