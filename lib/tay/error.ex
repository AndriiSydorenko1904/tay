defmodule Tay.Error do
  @moduledoc "Bounded API error. Unknown outcomes carry the stable job ID, never args or storage handles."
  defstruct [:kind, :reason, :job_id, :operation]

  def new(kind, reason, job_id \\ nil, operation \\ nil),
    do: %__MODULE__{kind: kind, reason: reason, job_id: job_id, operation: operation}
end
