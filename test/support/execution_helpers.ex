defmodule Tay.Test.ExecutionClock do
  @moduledoc false
  @behaviour Tay.Execution.Clock
  @impl true
  def wall_ms, do: Tay.Test.ExecutionHelpers.clock(:wall)
  @impl true
  def monotonic_ms, do: Tay.Test.ExecutionHelpers.clock(:monotonic)
end

defmodule Tay.Test.ExecutionWorker do
  @moduledoc false
  use Tay.Worker, key: "execution.test.v1"
  @impl true
  def perform(job), do: Tay.Test.ExecutionHelpers.perform(job)
end

defmodule Tay.Test.ExecutionHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Tay.Test.{EngineHelpers, ExecutionClock, ExecutionWorker}
  alias Tay.{Event, JobID}
  alias Tay.Storage.Segment
  alias Tay.State.Transition

  # Only test runtime state contains controller PIDs/functions. Persisted args
  # contain an inert token; no production registry or payload bypass is used.
  def install(wall \\ 1_000_000, monotonic \\ 0) do
    table = :ets.new(__MODULE__, [:named_table, :public, :set])
    :ets.insert(table, {:clock, wall, monotonic})
    :ok
  end

  def clock(kind) do
    [{:clock, wall, monotonic}] = :ets.lookup(__MODULE__, :clock)
    if kind == :wall, do: wall, else: monotonic
  end

  def set_clock(wall, monotonic \\ nil) do
    monotonic = if is_nil(monotonic), do: clock(:monotonic), else: monotonic
    :ets.insert(__MODULE__, {:clock, wall, monotonic})
    :ok
  end

  def initialize(path) do
    mode = if System.get_env("TAY_TEST_SYNC") == "1", do: :sync, else: :write

    assert {:ok, _} =
             Tay.Storage.initialize(
               data_dir: path,
               durability: mode,
               validated_filesystem: mode == :sync,
               test_helper: true
             )

    path
  end

  def options(path, name, extra \\ []) do
    EngineHelpers.options(
      path,
      name,
      Keyword.merge(
        [
          workers: %{"execution.test.v1" => ExecutionWorker},
          queues: [default: 1],
          test_execution: true,
          test_clock: ExecutionClock,
          execution_wake_ms: 10
        ],
        extra
      )
    )
  end

  def start(path, name, extra \\ []) do
    # Initialization/previous helpers close asynchronously. Only known ownership
    # contention is retried in this test assertion, never a submitted command.
    EngineHelpers.restart(path, name, options(path, name, extra))
  end

  def stop(root), do: EngineHelpers.stop(root)
  def engine(root), do: EngineHelpers.engine(root)

  def job(options \\ []) do
    token = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    :ets.insert(__MODULE__, {token, self(), 0})
    assert {:ok, job} = ExecutionWorker.new(%{"test_token" => token}, options)
    {job, token}
  end

  def perform(job) do
    token = job.args["test_token"]
    [{^token, controller, _}] = :ets.lookup(__MODULE__, token)
    :ets.update_counter(__MODULE__, token, {3, 1})
    metadata = Map.take(job, [:id, :attempt, :revision, :queue])
    send(controller, {:tay_test_entered, token, self(), metadata})
    receive_action()
  end

  defp receive_action do
    receive do
      {:return, result} ->
        result

      {:raise, term} ->
        :erlang.error(term)

      {:throw, term} ->
        throw(term)

      {:exit, term} ->
        exit(term)

      :trap_exits ->
        Process.flag(:trap_exit, true)
        receive_action()
    end
  end

  def entries(token), do: :ets.lookup_element(__MODULE__, token, 3)

  def await_entry(token, timeout \\ 5_000) do
    assert_receive {:tay_test_entered, ^token, task, metadata}, timeout
    {task, metadata}
  end

  def await_job(name, id, expected_state) do
    result =
      eventually(fn ->
        case Tay.get_job(id, name: name) do
          {:ok, %{state: ^expected_state} = job} -> job
          _ -> false
        end
      end)

    assert is_struct(result, Tay.Job),
           "job did not reach #{expected_state}; status=#{inspect(Tay.status(name: name))}"

    result
  end

  def wake(root) do
    state = :sys.get_state(engine(root))
    Enum.each(state.controls, fn {_, pid} -> Tay.Execution.Queue.wake(pid) end)
    :ok
  end

  def tick(root, wall, monotonic \\ nil) do
    set_clock(wall, monotonic)
    wake(root)
  end

  def runtime_entry(root, id) do
    {:ok, raw} = JobID.decode(id)

    eventually(fn ->
      :sys.get_state(engine(root)).running
      |> Enum.find(fn {_relay, entry} -> entry.id == raw end)
    end)
  end

  def due(%Tay.Job{scheduled_at: %DateTime{} = time}), do: DateTime.to_unix(time, :millisecond)
  def due(%Tay.Job{scheduled_at: time}) when is_integer(time), do: time

  def eventually(fun, timeout \\ 5_000),
    do: until(fun, System.monotonic_time(:millisecond) + timeout)

  defp until(fun, deadline) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          until(fun, deadline)
        else
          false
        end

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          until(fun, deadline)
        else
          false
        end

      result ->
        result
    end
  end

  # Invoke only with a stopped/quiescent test store. Production inspection uses
  # existing-only ownership; this independent oracle validates every segment and
  # frame before reconstructing the same pure lifecycle from captured bytes.
  def history(path) do
    directory = Path.join(path, "segments")

    files =
      File.ls!(directory)
      |> Enum.filter(&match?({:ok, _}, Segment.filename_id(&1)))
      |> Enum.sort()

    history =
      Enum.flat_map(files, fn file ->
        bytes = File.read!(Path.join(directory, file))
        read = fn offset, count -> {:ok, binary_part(bytes, offset, count)} end

        assert {:ok, _, events} =
                 Segment.reduce(read, byte_size(bytes), [], fn record, _offset, acc ->
                   assert {:ok, event, consumed} =
                            Event.decode_payload(
                              record.record_type,
                              record.payload_schema_version,
                              record.payload,
                              Tay.Event.Value.defaults()
                            )

                   assert consumed == byte_size(record.payload)
                   [%{sequence: record.sequence, event: event} | acc]
                 end)

        Enum.reverse(events)
      end)

    Enum.with_index(history, 1)
    |> Enum.each(fn {item, expected} -> assert item.sequence == expected end)

    history
  end

  def replay(path) do
    Enum.reduce(history(path), Transition.candidate(), fn item, candidate ->
      assert {:ok, candidate} =
               Transition.reduce(item.event, %{sequence: item.sequence}, candidate)

      candidate
    end)
  end
end
