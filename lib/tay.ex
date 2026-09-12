defmodule Tay do
  @moduledoc """
  The foundation of an embedded background job engine for Elixir.

  Phase 0 provides configuration, application startup, a runtime `Tay.Job`
  struct, and the `Tay.Worker` behaviour. Starting the application validates
  configuration and starts an empty supervisor.

  Phase 1 adds the pure `Tay.Storage.Record` framing/integrity codec with opaque
  payloads. Physical decoding is not semantic acceptance or applied replay.

  Phase 2 adds physical segmented storage through an explicitly supervised
  internal Writer and its native filesystem Port. Semantic recovery, insertion,
  scheduling, and execution are not implemented.
  Application startup does not indicate storage readiness or durability.
  """
end
