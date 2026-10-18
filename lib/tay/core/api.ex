defmodule Tay.Core.API do
  @moduledoc false

  @type target :: term()

  @callback enqueue(target(), String.t(), map(), keyword()) :: term()
  @callback get_job(target(), String.t()) :: term()
  @callback cancel(target(), String.t()) :: term()
  @callback result(target(), String.t()) :: term()
  @callback register_schedule(target(), Tay.Schedule.t()) :: term()
  @callback cancel_schedule(target(), String.t(), non_neg_integer()) :: term()
  @callback advance_schedule(
              target(),
              String.t(),
              non_neg_integer(),
              integer(),
              integer(),
              integer()
            ) ::
              term()

  @spec call({module(), term()}, atom(), list()) :: term()
  def call({adapter, target}, operation, arguments)
      when is_atom(adapter) and is_atom(operation) and is_list(arguments) do
    apply(adapter, operation, [target | arguments])
  end
end
