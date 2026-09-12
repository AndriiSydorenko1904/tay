defmodule Tay.Worker do
  @moduledoc """
  The callback contract for a worker that accepts a `Tay.Job`.

  Implement with `@behaviour Tay.Worker` and a `perform/1` callback.
  `:ok` and `{:ok, result}` describe successful callback returns;
  `{:error, reason}` describes an unsuccessful return. Returned values are
  runtime terms, not an approved persisted representation.

  Phase 0 has no executor. Handling crashes, exits, timeouts, results and retries
  belongs to later execution phases. The `use Tay.Worker` macro and worker
  `new/1` helpers are not provided yet.
  """

  @callback perform(Tay.Job.t()) :: :ok | {:ok, term()} | {:error, term()}
end
