defmodule Tay.Engine.Operations do
  @moduledoc false
  alias Tay.Engine.Admission
  alias Tay.{Error, Execution.LocalFence}
  @test Mix.env() == :test

  # One fixed metadata-only permit is independent of saturated client/drain
  # permits. No unbounded public operational waiting queue is created.
  def call(name, operation, force, timeout)
      when is_atom(name) and name not in [nil, false, true] and
             operation in [:stop, :restart] and is_boolean(force) do
    with {:ok, meta} <- Admission.metadata(name),
         timeout = timeout || meta.timeout,
         true <- is_integer(timeout) and timeout in 1..4_294_967_295,
         token = make_ref(),
         deadline = System.monotonic_time(:millisecond) + timeout,
         true <-
           Admission.cas(
             name,
             {:operation, nil, nil, :free, 0},
             {:operation, token, self(), :claimed, deadline}
           ) do
      try do
        GenServer.call(
          meta.guardian,
          {:operation, meta.generation, token, operation, force, deadline},
          timeout
        )
      catch
        :exit, _ -> {:error, Error.new(:unknown_outcome, :operation_reply_lost, nil, operation)}
      after
        send(meta.guardian, {:cancel_operation_claim, self(), token})
      end
    else
      false -> {:error, Error.new(:capacity, :operation_slot, nil, operation)}
      _ -> {:error, Error.new(:unavailable, :generation_unavailable, nil, operation)}
    end
  rescue
    ArgumentError -> {:error, Error.new(:unavailable, :generation_unavailable, nil, operation)}
  end

  def call(_, operation, _, _),
    do: {:error, Error.new(:invalid, :invalid_options, nil, operation)}

  def draining?(name, generation, token, guardian) do
    with {:ok, %{generation: ^generation, guardian: ^guardian}} <- Admission.metadata(name),
         [{:operation, ^token, _, :submitted, _}] <- :ets.lookup(name, :operation),
         do: true,
         else: (_ -> false)
  rescue
    ArgumentError -> false
  end

  # This single trusted driver may wait for actual process death, never guessed
  # death after a timeout. Caller deadlines remain bounded in the Guardian.
  # Only the original host-owned supervisor starts replacement children.
  def drive(guardian, root, config, token, old, operation) do
    Process.flag(:trap_exit, true)

    result =
      with :ok <- terminate_child(root, Tay.Engine),
           :ok <- terminate_child(root, Tay.Execution.Supervisor),
           :ok <- wait_dead([old.engine, old.writer, old.runtime]),
           :ok <- wait_retired(old.fence) do
        case operation do
          :stop -> stop_probe(config)
          :restart -> restart(guardian, root, config, token)
        end
      end

    if @test and is_function(Map.get(config, :test_hook), 1),
      do: config.test_hook.({:operations, :pre_result})

    send(guardian, {:operation_result, self(), token, result})
  catch
    _, _ -> send(guardian, {:operation_result, self(), token, {:error, :lifecycle_driver_failed}})
  end

  defp terminate_child(root, id) do
    case Supervisor.terminate_child(root, id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, :lifecycle_shutdown_failed}
    end
  end

  defp wait_dead(pids) do
    for pid <- Enum.filter(pids, &is_pid/1) do
      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end

    :ok
  end

  defp wait_retired(nil), do: :ok

  defp wait_retired(lease) do
    case LocalFence.retired?(lease) do
      true ->
        :ok

      false ->
        Process.sleep(10)
        wait_retired(lease)

      _ ->
        {:error, :local_fence_lost}
    end
  end

  defp stop_probe(config) do
    # A single existing-only acquisition proves the old native flock is no
    # longer held. This is not bootstrap, activation or a recovery ticket.
    options = [
      durability: config.durability,
      validated_filesystem: config.validated_filesystem,
      timeout: config.storage_timeout
    ]

    case Tay.Storage.Native.open_existing(config.data_dir, options) do
      {:ok, native} ->
        case Tay.Storage.Native.shutdown(native) do
          :ok -> :ok
          _ -> {:error, :ownership_unconfirmed}
        end

      _ ->
        {:error, :ownership_unconfirmed}
    end
  end

  defp restart(guardian, root, config, token) do
    with :ok <- GenServer.call(guardian, {:operation_starting, token, self()}),
         :ok <- Tay.Engine.Supervisor.start_generation(root, config),
         do: :ok
  end
end
