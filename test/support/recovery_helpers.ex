defmodule Tay.Test.RecoveryDecoder do
  @moduledoc false
  @behaviour Tay.Storage.Recovery.EventDecoder
  # Artificial test vocabulary, not a production registry or serialization.
  @impl true
  def known_type?(type), do: type in [47, 48]
  @impl true
  def supported_schema?(_, schema), do: schema == 3
  @impl true
  def decode_payload(_, _, payload, limits) do
    cond do
      byte_size(payload) > limits.binary_bytes -> {:error, {:resource_limit, :binary_bytes}}
      limits.depth < 2 -> {:error, {:resource_limit, :depth}}
      limits.output_nodes < 2 -> {:error, {:resource_limit, :output_nodes}}
      payload == <<>> -> {:ok, {:value, 0}, 0}
      byte_size(payload) == 1 -> {:ok, {:value, :binary.first(payload)}, 1}
      true -> {:error, :invalid_test_payload}
    end
  end
end

defmodule Tay.Test.RecoveryProbeDecoder do
  @moduledoc false
  @behaviour Tay.Storage.Recovery.EventDecoder
  @impl true
  def known_type?(type) do
    probe({:known, type})

    case Process.get(:recovery_test_known) do
      nil -> Tay.Test.RecoveryDecoder.known_type?(type)
      fun -> fun.(type)
    end
  end

  @impl true
  def supported_schema?(type, schema) do
    probe({:schema, type, schema})
    Tay.Test.RecoveryDecoder.supported_schema?(type, schema)
  end

  @impl true
  def decode_payload(type, schema, payload, limits) do
    probe({:decode, payload})

    case Process.get(:recovery_test_decoder) do
      nil -> Tay.Test.RecoveryDecoder.decode_payload(type, schema, payload, limits)
      fun -> fun.(type, schema, payload, limits)
    end
  end

  defp probe(message) do
    if pid = Process.get(:recovery_test_observer), do: send(pid, message)
  end
end

defmodule Tay.Test.RecoverySizeDecoder do
  @moduledoc false
  @behaviour Tay.Storage.Recovery.EventDecoder
  @impl true
  def known_type?(type), do: type == 47
  @impl true
  def supported_schema?(_, schema), do: schema == 3
  @impl true
  def decode_payload(_, _, payload, limits) do
    cond do
      limits.depth < 2 -> {:error, {:resource_limit, :depth}}
      limits.output_nodes < 2 -> {:error, {:resource_limit, :output_nodes}}
      byte_size(payload) > limits.binary_bytes -> {:error, {:resource_limit, :binary_bytes}}
      true -> {:ok, {:size, byte_size(payload)}, byte_size(payload)}
    end
  end
end

defmodule Tay.Test.RecoveryReloadDecoder do
  @moduledoc false
  @behaviour Tay.Storage.Recovery.EventDecoder
  @impl true
  defdelegate known_type?(type), to: Tay.Test.RecoveryDecoder
  @impl true
  defdelegate supported_schema?(type, schema), to: Tay.Test.RecoveryDecoder
  @impl true
  defdelegate decode_payload(type, schema, payload, limits), to: Tay.Test.RecoveryDecoder

  def replace_for_test do
    :code.delete(__MODULE__)

    Code.compile_quoted(
      quote do
        defmodule Tay.Test.RecoveryReloadDecoder do
          def known_type?(_), do: false
          def supported_schema?(_, _), do: false
          def decode_payload(_, _, _, _), do: {:error, :changed_test_provider}
        end
      end
    )
  end
end

defmodule Tay.Test.RecoveryHelpers do
  @moduledoc false
  alias Tay.Storage.{Native, Writer}
  alias Tay.Test.{NativeHelpers, RecordHelpers, SegmentHelpers}

  def spec(options \\ []),
    do: %{codec: Tay.Test.RecoveryDecoder, initial_acc: [], reducer: &collect/3, options: options}

  def collect({:value, value}, position, acc), do: {:ok, [{position.sequence, value} | acc]}

  def frame(sequence, value \\ 1, fields \\ []),
    do:
      RecordHelpers.frame(
        Keyword.merge(
          [sequence: sequence, record_type: 47, payload_schema_version: 3, payload: <<value>>],
          fields
        )
      )

  def segment(id, first, records, sealed \\ false) do
    header = SegmentHelpers.header(id: id, first_sequence: first)
    footer = if sealed, do: SegmentHelpers.footer(header, records), else: <<>>
    IO.iodata_to_binary([header, records, footer])
  end

  # All direct writes/changes are to disposable test fixtures; Recovery itself
  # must preserve the snapshot, including retained stages and lock identity.
  def store(path, segments \\ [segment(1, 1, [])]) do
    File.mkdir_p!(Path.join(path, "segments"))
    File.write!(Path.join(path, ".tay-owner.lock"), <<>>)
    File.write!(Path.join(path, "STORE"), SegmentHelpers.fixture("STORE"))

    Enum.with_index(segments, 1)
    |> Enum.each(fn {bytes, id} -> File.write!(canonical(path, id), bytes) end)

    path
  end

  def canonical(path, id), do: Path.join([path, "segments", NativeHelpers.canonical(id)])

  def open(path, options \\ []),
    do:
      Native.open_existing(
        path,
        Keyword.merge([durability: :write, test_helper: true], options)
      )

  def start(path, replay_spec \\ spec(), options \\ []),
    do:
      Writer.start_recovered_link(
        Keyword.merge([data_dir: path, durability: :write, test_helper: true], options),
        replay_spec
      )

  def activate(writer), do: Writer.activate_recovered(writer, Writer.status(writer).session_ref)

  # A killed/closed Port's OS process releases flock asynchronously. This is a
  # bounded test assertion about eventual release, never a production retry.
  def after_release(fun), do: after_release(fun, System.monotonic_time(:millisecond) + 5_000)

  defp after_release(fun, deadline) do
    result = fun.()

    busy =
      case result do
        {:error, %{kind: :ownership_busy}} -> true
        {:error, %{reason: "store_busy"}} -> true
        _ -> false
      end

    if busy and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      after_release(fun, deadline)
    else
      result
    end
  end

  def snapshot(path) do
    if File.exists?(path), do: snapshot(path, ""), else: :absent
  end

  defp snapshot(path, relative) do
    full = Path.join(path, relative)
    stat = File.lstat!(full)
    identity = Map.take(stat, [:type, :size, :inode, :major_device, :minor_device, :links, :mode])

    case stat.type do
      :directory ->
        {relative, identity,
         File.ls!(full) |> Enum.sort() |> Enum.map(&snapshot(path, Path.join(relative, &1)))}

      :regular ->
        {relative, identity, File.read!(full)}

      :symlink ->
        {relative, identity, File.read_link!(full)}

      _ ->
        {relative, identity}
    end
  end
end
