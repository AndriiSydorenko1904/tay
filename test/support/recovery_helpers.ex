defmodule Tay.Test.RecoveryHelpers do
  @moduledoc false
  alias Tay.State.Transition
  alias Tay.Storage.{Native, Writer}
  alias Tay.Storage.V2.Codec
  alias Tay.Test.NativeHelpers

  # All direct writes/changes are to disposable test fixtures; Recovery itself
  # must preserve the snapshot, including retained stages and lock identity.
  def store(path) do
    {:ok, _} = Tay.Storage.initialize(data_dir: path, durability: :write)
    path
  end

  def canonical(path, id), do: Path.join(segment_directory(path), NativeHelpers.canonical(id))

  def segment_directory(path) do
    current = Path.join(path, "CURRENT")

    if File.regular?(current) do
      {:ok, pointer} = Tay.Storage.V2.Authority.decode_current(File.read!(current))
      epoch = "e-" <> Base.encode16(pointer.epoch_id, case: :lower)
      Path.join([path, "epochs", epoch, "segments"])
    else
      Path.join(path, "segments")
    end
  end

  def open(path, options \\ []),
    do:
      Native.open_existing(
        path,
        Keyword.merge([durability: :write, test_helper: true], options)
      )

  def start(path, replay_spec, options \\ []),
    do:
      Writer.start_recovered_link(
        Keyword.merge([data_dir: path, durability: :write, test_helper: true], options),
        replay_spec
      )

  def activate(writer), do: Writer.activate_recovered(writer, Writer.status(writer).session_ref)

  def write_v2_mutations(path, producer) when is_function(producer, 1) do
    replay_spec = %{
      codec: Tay.Event,
      initial_acc: Transition.candidate(),
      reducer: &Tay.Engine.CompactionReplay.reduce/3,
      options: [deadline_ms: 900_000, activation_deadline_ms: 900_000]
    }

    {:ok, writer} = start(path, replay_spec, timeout: 900_000)
    Process.unlink(writer)

    try do
      {:ok, summary, _candidate} = activate(writer)

      append = fn mutation ->
        {:ok, payload} = Codec.encode_mutation(mutation)

        {:ok, _receipt} =
          Writer.append(writer, summary.admission_ref, Codec.mutation_type(), 1, payload)

        :ok
      end

      result = producer.(append)
      result
    after
      if Process.alive?(writer), do: GenServer.stop(writer)
    end
  end

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
