defmodule Tay.Worker do
  @moduledoc """
  The callback contract for a worker that accepts a `Tay.Job`.

  Implement with `@behaviour Tay.Worker` and a `perform/1` callback.
  `:ok` and `{:ok, result}` describe successful callback returns;
  `{:error, reason}` describes an unsuccessful return. Returned values are
  runtime terms, not an approved persisted representation.

  `use Tay.Worker, key: "stable.key"` provides pure job builders. The configured
  Engine maps that stable key to a trusted module and executes `perform/1` only
  after a durable start Event. Worker return terms are not persisted; only a
  bounded outcome diagnostic and final retry/discard decision are logged.
  """

  @callback perform(Tay.Job.t()) :: :ok | {:ok, term()} | {:error, term()}

  defmacro __using__(options) do
    unless Keyword.keyword?(options) and Keyword.has_key?(options, :key) and
             length(options) == length(Enum.uniq(Keyword.keys(options))) and
             Enum.all?(Keyword.keys(options), &(&1 in [:key, :queue, :max_attempts, :timeout_ms])) do
      raise ArgumentError, "Tay.Worker requires an explicit key and recognized builder options"
    end

    defaults =
      options |> Keyword.put(:worker_key, Keyword.fetch!(options, :key)) |> Keyword.delete(:key)

    quote do
      @behaviour Tay.Worker
      @tay_worker_defaults unquote(defaults)
      def __tay_worker__, do: @tay_worker_defaults
      def new(args, options \\ []), do: Tay.Job.new(__MODULE__, args, options)
    end
  end
end
