defmodule Tay.Job do
  @moduledoc """
  An initial, in-memory job description.

  A new struct has no ID, lifecycle state, or timestamps. Constructing one
  neither inserts a job nor marks it available for execution. Phase 0 does
  not generate IDs, validate transitions, or persist this representation.

  The fields and types describe runtime data only. They do not define a durable
  payload schema, argument encoding, ID format, or error-retention policy.
  """

  defstruct id: nil,
            worker: nil,
            queue: :default,
            args: %{},
            state: nil,
            attempt: 0,
            max_attempts: 10,
            inserted_at: nil,
            scheduled_at: nil,
            attempted_at: nil,
            completed_at: nil,
            errors: []

  @type t :: %__MODULE__{
          id: binary() | nil,
          worker: module() | nil,
          queue: atom(),
          args: map(),
          state: atom() | nil,
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          inserted_at: DateTime.t() | nil,
          scheduled_at: DateTime.t() | nil,
          attempted_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          errors: [term()]
        }
end
