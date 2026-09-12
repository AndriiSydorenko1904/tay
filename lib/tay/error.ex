defmodule Tay.Error do
  @moduledoc """
  Bounded API error. Unknown outcomes carry the stable job ID and the captured
  administrative revision, never args or storage handles. A revision is runtime
  context for explicit reconciliation, not permission to retry automatically.
  """
  defstruct [:kind, :reason, :job_id, :operation, :expected_revision]

  def new(kind, reason, job_id \\ nil, operation \\ nil, expected_revision \\ nil),
    do: %__MODULE__{
      kind: kind,
      reason: reason,
      job_id: job_id,
      operation: operation,
      expected_revision: expected_revision
    }
end
