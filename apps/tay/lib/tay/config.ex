defmodule Tay.Config do
  @moduledoc """
  Loads and validates Tay's foundation configuration without storage I/O.

  Supported options:

    * `:data_dir` — a nonblank UTF-8 path without NUL bytes, or `nil` when
      unconfigured. Relative paths are expanded against the current working
      directory when configuration is loaded. Expansion is lexical: it does
      not resolve symlinks, create directories, or verify permissions.
    * `:queues` — a keyword list of unique atom names and positive integer
      concurrency limits, defaulting to `[default: 10]`. `[]` is allowed.
    * `:durability` — default job durability, `:persistent` (the default) or
      `:volatile`.
    * `:journal` — global persistent-journal batching configuration.

  This module has no default storage path. This repository supplies provisional
  dev/test paths in `config/config.exs`; these are not production storage-location
  semantics. An unconfigured path is accepted by development/test application
  startup only. Production startup requires an explicitly configured path.

  Unknown and duplicate options are rejected. Queue strings are not converted
  to atoms. Storage-session durability (`:sync` or development-only `:write`)
  remains an Engine/Storage option and is distinct from job durability.
  """

  @default_journal [batch: [max_events: 1, interval_ms: 0]]
  defstruct data_dir: nil,
            queues: [default: 10],
            durability: :persistent,
            journal: @default_journal

  @environment Mix.env()

  @doc "Enforces the production storage-location requirement without filesystem I/O."
  def validate_startup(config, environment \\ @environment)

  def validate_startup(%__MODULE__{data_dir: nil}, :prod),
    do: invalid(:data_dir, "must be explicitly configured in production")

  def validate_startup(%__MODULE__{}, _environment), do: :ok

  @type t :: %__MODULE__{
          data_dir: String.t() | nil,
          queues: [{atom(), pos_integer()}],
          durability: :persistent | :volatile,
          journal: keyword()
        }

  @type error :: {:invalid_config, atom(), String.t()}

  @doc """
  Validates options and normalizes a configured path without changing the
  application environment or touching storage.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(options) do
    with :ok <- validate_options(options),
         {:ok, data_dir} <- normalize_data_dir(Keyword.get(options, :data_dir)),
         {:ok, queues} <- validate_queues(Keyword.get(options, :queues, default_queues())),
         {:ok, durability} <- validate_durability(Keyword.get(options, :durability, :persistent)),
         {:ok, journal} <- validate_journal(Keyword.get(options, :journal, @default_journal)) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         queues: queues,
         durability: durability,
         journal: journal
       }}
    end
  end

  @doc """
  Reads the current `:tay` application environment and validates it.

  Values are read on each call, rather than captured at compile time.
  """
  @spec load() :: {:ok, t()} | {:error, error()}
  def load do
    new(Application.get_all_env(:tay))
  end

  defp default_queues, do: [default: 10]

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          invalid(:options, "must not contain duplicate keys")

        Enum.any?(keys, &(&1 not in [:data_dir, :queues, :durability, :journal])) ->
          invalid(:options, "contains an unsupported key")

        true ->
          :ok
      end
    else
      invalid(:options, "must be a keyword list")
    end
  end

  defp normalize_data_dir(nil), do: {:ok, nil}

  defp normalize_data_dir(path) when is_binary(path) do
    cond do
      not String.valid?(path) ->
        invalid(:data_dir, "must contain valid UTF-8")

      String.trim(path) == "" ->
        invalid(:data_dir, "must not be blank")

      String.contains?(path, <<0>>) ->
        invalid(:data_dir, "must not contain NUL bytes")

      true ->
        {:ok, Path.expand(path)}
    end
  end

  defp normalize_data_dir(_path) do
    invalid(:data_dir, "must be a path string or nil")
  end

  defp validate_queues(queues) do
    if Keyword.keyword?(queues) do
      names = Keyword.keys(queues)

      cond do
        length(names) != length(Enum.uniq(names)) ->
          invalid(:queues, "queue names must be unique")

        not Enum.all?(queues, fn {_name, limit} -> is_integer(limit) and limit > 0 end) ->
          invalid(:queues, "concurrency limits must be positive integers")

        true ->
          {:ok, queues}
      end
    else
      invalid(:queues, "must be a keyword list with atom queue names")
    end
  end

  defp validate_durability(mode) when mode in [:persistent, :volatile], do: {:ok, mode}
  defp validate_durability(_), do: invalid(:durability, "must be :persistent or :volatile")

  defp validate_journal(journal) do
    with true <- exact_keyword?(journal, [:batch]),
         batch <- Keyword.fetch!(journal, :batch),
         true <- exact_keyword?(batch, [:max_events, :interval_ms]),
         max_events <- Keyword.fetch!(batch, :max_events),
         interval <- Keyword.fetch!(batch, :interval_ms),
         true <- is_integer(max_events) and max_events in 1..65_536,
         true <- is_integer(interval) and interval in 0..1_000 do
      {:ok, [batch: [max_events: max_events, interval_ms: interval]]}
    else
      _ -> invalid(:journal, "must contain a bounded :batch configuration")
    end
  end

  defp exact_keyword?(value, keys) do
    Keyword.keyword?(value) and Enum.sort(Keyword.keys(value)) == Enum.sort(keys)
  end

  defp invalid(key, message), do: {:error, {:invalid_config, key, message}}
end
