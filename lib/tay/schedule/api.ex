defmodule Tay.Schedule.API do
  @moduledoc false

  @callback register(term(), map()) :: term()
  @callback cancel(term(), String.t()) :: term()

  def call({adapter, target}, operation, arguments),
    do: apply(adapter, operation, [target | arguments])
end
