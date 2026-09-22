defmodule Tay.Queue do
  @moduledoc "A stable public snapshot of one configured Tay queue."

  @enforce_keys [:key, :name, :paused, :concurrency, :executing, :jobs, :states]
  defstruct [:key, :name, :paused, :concurrency, :executing, :jobs, :states]

  @type t :: %__MODULE__{
          key: String.t(),
          name: atom(),
          paused: boolean(),
          concurrency: pos_integer(),
          executing: non_neg_integer(),
          jobs: non_neg_integer(),
          states: %{atom() => non_neg_integer()}
        }
end
