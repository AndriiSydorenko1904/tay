defmodule Tay.Storage.Recovery.Error do
  @moduledoc "Bounded recovery diagnostics. No error authorizes repair or prefix publication."
  defstruct [
    :stage,
    :kind,
    :reason,
    :store_id,
    :segment_id,
    :offset,
    :sequence,
    :physical_reason,
    :cleanup_error,
    action: :preserve_and_stop,
    mutation: :none
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), term(), atom(), map()) :: t()
  def new(kind, reason, stage, position \\ %{}) do
    struct!(
      __MODULE__,
      Map.merge(
        Map.take(position, [:store_id, :segment_id, :offset, :sequence]),
        %{stage: stage, kind: kind, reason: bounded(reason)}
      )
    )
  end

  @spec wrap(term(), atom(), map()) :: t()
  def wrap(reason, stage, position \\ %{})
  def wrap(%__MODULE__{} = error, _stage, _position), do: error

  def wrap(%{kind: :visitor_error, reason: %__MODULE__{} = error} = outer, _, _),
    do: %{
      error
      | segment_id: error.segment_id || Map.get(outer, :segment_id),
        offset: error.offset || Map.get(outer, :offset)
    }

  def wrap(reason, stage, position) do
    position =
      if is_map(reason),
        do: Map.merge(position, Map.take(reason, [:segment_id, :offset])),
        else: position

    kind = if stage == :validation, do: :argument, else: classify(reason)
    error = new(kind, reason, stage, position)
    %{error | physical_reason: bounded(reason)}
  end

  defp classify(%{reason: "store_busy"}), do: :ownership_busy
  defp classify(%{reason: "path_or_extent_changed"}), do: :changed_view
  defp classify(%{reason: "resource_limit"}), do: :resource_limit
  defp classify(%{kind: :resource_limit}), do: :resource_limit
  defp classify(%{kind: :native_argument}), do: :argument
  defp classify(%{kind: :native_owner}), do: :ownership_unavailable
  defp classify(%{kind: k}) when k in [:native_io, :native_start, :uncertain], do: :io

  defp classify(%{kind: k})
       when k in [
              :ambiguous_short_tail,
              :incomplete_record,
              :incomplete_footer,
              :incomplete_segment_header
            ],
       do: :incomplete_tail

  defp classify(%{kind: k}) when k in [:unsupported_segment_version, :unsupported_segment_flags],
    do: :unsupported_physical

  defp classify(%{reason: {:error, {:unsupported, _}}}), do: :unsupported_physical

  defp classify(%{reason: {:error, {k, _}}}) when k in [:unsupported_version, :unsupported_flags],
    do: :unsupported_physical

  defp classify(%{reason: {:error, {:resource_limit, _, _}}}), do: :resource_limit

  defp classify(%{reason: {:error, %{kind: k}}})
       when k in [:resource_limit, :native_io, :uncertain],
       do: if(k == :resource_limit, do: :resource_limit, else: :io)

  defp classify(%{kind: :io_or_resource_error}), do: :io
  defp classify(%{reason: {:sequence, _, _}}), do: :continuity
  defp classify(%{reason: {:first_sequence, _, _, _}}), do: :continuity
  defp classify(%{kind: :discovery_error}), do: :discovery
  defp classify(_), do: :physical_corruption

  # Physical reasons contain no payloads. Bound depth, collections and binaries
  # even for adversarial names. Callback reasons use a stricter, binary-free path.
  def bounded(term), do: bound(term, 0)
  defp bound(_, depth) when depth >= 8, do: :redacted
  defp bound(term, _) when is_atom(term), do: term

  defp bound(term, _)
       when is_integer(term) and term >= -18_446_744_073_709_551_615 and
              term <= 18_446_744_073_709_551_615,
       do: term

  defp bound(term, _) when is_binary(term) and byte_size(term) <= 128, do: :binary.copy(term)

  defp bound(term, depth) when is_tuple(term) and tuple_size(term) <= 8,
    do: term |> Tuple.to_list() |> Enum.map(&bound(&1, depth + 1)) |> List.to_tuple()

  defp bound(term, depth) when is_map(term) do
    term
    |> Map.take([
      :kind,
      :reason,
      :operation,
      :errno,
      :bytes_written,
      :segment_id,
      :offset,
      :available_bytes,
      :expected_bytes,
      :missing_bytes,
      :format_version,
      :record_type,
      :flags,
      :payload_schema_version,
      :sequence,
      :payload_length,
      :record_bytes
    ])
    |> Map.new(fn {key, value} -> {key, bound(value, depth + 1)} end)
  end

  defp bound(_, _), do: :redacted

  @doc false
  def callback_reason(term) when is_atom(term), do: term
  def callback_reason({:resource_limit, limit}) when is_atom(limit), do: {:resource_limit, limit}
  def callback_reason(_), do: :callback_reason_redacted
end
