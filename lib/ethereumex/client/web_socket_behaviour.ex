defmodule Ethereumex.Client.WebSocketBehaviour do
  @moduledoc false
  alias Ethereumex.Subscription

  @type error :: {:error, map() | binary() | atom()}

  # API methods

  @callback eth_subscribe(
              event :: Subscription.event(),
              param :: Subscription.params(),
              keyword()
            ) :: {:ok, subscription :: Subscription.t()} | error

  @callback eth_unsubscribe(subscription :: Subscription.t(), keyword()) :: :ok | error

  # actual request methods

  @callback request(binary(), list(boolean() | binary()), keyword()) ::
              {:ok, any() | [any()]} | error
  @callback single_request(map(), keyword()) :: {:ok, any() | [any()]} | error
  @callback batch_request([{atom(), list(boolean() | binary())}], keyword()) ::
              {:ok, [any()]} | error
end
