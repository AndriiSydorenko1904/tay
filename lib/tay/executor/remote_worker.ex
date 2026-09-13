defmodule Tay.Executor.RemoteWorker do
  @moduledoc false

  # A deliberately inert marker used only while constructing a Job for the
  # Protocol v1 intake.  It is never resolved from persisted text and it has
  # no `perform/1` callback, so an untrusted task name cannot become an Elixir
  # module/function invocation.
end
