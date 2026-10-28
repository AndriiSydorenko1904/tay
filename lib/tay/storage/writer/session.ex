defmodule Tay.Storage.Writer.Session do
  @moduledoc false
  alias Tay.Storage.Native
  alias Tay.Storage.Writer.State
  @test Mix.env() == :test

  def inspection_cache do
    :ets.new(:tay_storage_preview_cache, [
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  def poison(%{poisoned: nil} = state, reason) do
    # Revoke the embedding generation before potentially slow native cleanup.
    notify_lifecycle(state, :poisoned)
    Native.shutdown(state.native)
    _ = hook(state, {:poisoned, reason})

    State.poisoned(state, reason)
  end

  def poison(state, _reason), do: state

  def notify_lifecycle(state, event) do
    if pid = state.options.lifecycle_observer,
      do: send(pid, {Tay.Storage.Writer, self(), event})

    :ok
  end

  if @test do
    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)

    defp hook(_, _), do: :ok
  else
    defp hook(_, _), do: :ok
  end
end
