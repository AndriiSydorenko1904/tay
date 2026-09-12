defmodule Tay.Engine do
  @moduledoc """
  One generation's semantic command owner and sole private-index owner.
  Phase 4 produces insertion Events only. Recovered executing jobs remain inert.
  """
  use GenServer, restart: :temporary
  alias Tay.{Event, Error, Job, JobID}
  alias Tay.Event.{V1, Value}
  alias Tay.Engine.{Admission, Config}
  alias Tay.State.{Transition, Projection, JobIndex}
  alias Tay.Storage.{Writer, Segment}
  @test Mix.env() == :test

  def start_link(config), do: GenServer.start_link(__MODULE__, config, timeout: :infinity)

  def init(config) do
    guardian = Process.whereis(config.name)
    Process.monitor(guardian)

    with {:ok, generation} <- GenServer.call(guardian, {:attach_engine, self()}),
         {:ok, writer} <-
           Writer.start_recovered_link(
             Config.storage(config) ++ [lifecycle_observer: guardian],
             %{
               codec: Event,
               initial_acc: Transition.candidate(config.candidate_limits, config.value_limits),
               reducer: &Transition.reduce/3,
               options: config.recovery
             }
           ),
         :ok <- GenServer.call(guardian, {:attach_writer, writer}),
         {:ok, summary, candidate} <-
           Writer.activate_recovered(writer, Writer.status(writer).session_ref) do
      if match?({:error, _}, activation_capability(summary)) do
        GenServer.stop(writer)
        {:error, error} = activation_capability(summary)
        {:stop, error}
      else
        hook(config, :activated)
        projection = Projection.new(config.workers, config.queues, Map.get(config, :test_hook))
        hook(config, :indexes_created)
        projection = Projection.load(projection, candidate.jobs)
        true = Projection.valid?(projection)
        budget = Transition.accounting(candidate)
        # No copy of candidate.jobs survives init; private ETS is the only live
        # job projection. Startup accounting reserves up to three charged views.
        state = %{
          config: config,
          guardian: guardian,
          generation: generation,
          writer: writer,
          admission: summary.admission_ref,
          projection: projection,
          budget: budget,
          store_id: summary.store_id,
          next_sequence: summary.arithmetic_next_sequence,
          segment: Map.take(summary.highest, [:id, :bytes, :count, :state]),
          blocked:
            JobIndex.fold(
              projection.jobs,
              fn job, n ->
                if not Map.has_key?(config.workers, job.definition["worker_key"]) or
                     not Map.has_key?(config.queues, job.definition["queue_key"]),
                   do: n + 1,
                   else: n
              end,
              0
            )
        }

        hook(config, :pre_ready)

        case Writer.status(writer) do
          %{state: :ready, durability: mode} when mode == config.durability ->
            :ok = GenServer.call(guardian, {:ready, snapshot(state)})
            {:ok, state}

          _ ->
            {:stop, Error.new(:unavailable, :writer_unavailable)}
        end
      end
    else
      {:error, reason} -> {:stop, startup_error(reason)}
    end
  end

  @doc false
  def activation_capability(%{state: :terminal, admission_ref: nil}),
    do: {:error, Error.new(:capacity, :coordinate_space_exhausted)}

  def activation_capability(%{state: :ready, admission_ref: reference})
      when is_reference(reference),
      do: {:ok, reference}

  def activation_capability(_), do: {:error, Error.new(:unavailable, :invalid_activation_result)}

  # Only the trusted guardian sends a command with a submitted permit. An old
  # generation cannot address a newly constructed Engine or use its capability.
  def handle_info({:command, generation, permit, intent, from}, %{generation: generation} = s) do
    if submitted?(s, permit, from) do
      {reply, next} = command(intent, s)
      hook(s.config, :pre_reply)
      GenServer.reply(from, reply)
      hook(s.config, :post_reply)
      {slot, token} = permit
      send(s.guardian, {:completed, self(), slot, token, snapshot(next)})
      {:noreply, next}
    else
      {:noreply, s}
    end
  end

  def handle_info({:DOWN, _, :process, guardian, _}, %{guardian: guardian} = s),
    do: {:stop, :guardian_lost, s}

  def handle_info(_, s), do: {:noreply, s}

  defp submitted?(s, {slot, token}, {owner, _}) do
    with {:ok, meta} <- Admission.metadata(s.config.name),
         true <- meta.generation == s.generation and meta.status.state == :ready,
         [{^slot, ^token, ^owner, :submitted, _}] <- :ets.lookup(s.config.name, slot),
         do: true,
         else: (_ -> false)
  end

  defp command({:get, raw}, s) do
    result =
      case JobIndex.get(s.projection.jobs, raw) do
        nil -> {:error, :not_found}
        job -> {:ok, view(s, job)}
      end

    {result, s}
  end

  defp command({:insert, raw, worker, bytes}, s) do
    existing = JobIndex.get(s.projection.jobs, raw)

    cond do
      existing && existing.definition_bytes == bytes -> {{:ok, view(s, existing)}, s}
      existing -> failure(s, :invalid, :id_conflict, raw)
      true -> insert_new(s, raw, worker, bytes)
    end
  end

  defp command(_, s), do: {{:error, Error.new(:invalid, :invalid_request)}, s}

  defp insert_new(s, raw, worker, bytes) do
    c = s.config

    with {:ok, definition} <- Value.decode(bytes, c.value_limits),
         true <- V1.definition?(definition) || {:error, :invalid_definition},
         true <-
           (Map.get(c.workers, definition["worker_key"]) == worker and not is_nil(worker)) ||
             {:error, :worker_mapping},
         at = System.system_time(:millisecond),
         event = %Event{
           record_type: 1,
           data: %{
             "at" => at,
             "expected_revision" => 0,
             "job_id" => raw,
             "definition" => definition,
             "eligible_at" => definition["scheduled_at"] || at
           }
         },
         limits = %{
           c.value_limits
           | depth: c.insert_value_depth,
             output_nodes: c.insert_value_nodes
         },
         {:ok, {1, 1, payload}} <- Event.encode(event, limits, c.max_insert_payload_bytes),
         {:ok, _} <- Value.measure(definition["args"], limits, c.max_insert_args_bytes),
         {:ok, effect} <- Transition.prepare(nil, event, c.value_limits),
         :ok <- headroom(s, byte_size(payload)),
         {:ok, predicted} <- Transition.apply(effect, %{sequence: s.next_sequence}),
         {:ok, _, budget} <- Transition.account(s.budget, nil, predicted) do
      hook(c, :pre_append)

      case Writer.append(s.writer, s.admission, 1, 1, payload) do
        {:ok, receipt} ->
          expected = expected_position(s, byte_size(payload))

          if receipt != Map.put(expected, :durability, c.durability),
            do: exit(:invalid_writer_receipt)

          hook(c, :post_append)
          {:ok, job} = Transition.apply(effect, receipt)
          {:ok, job, ^budget} = Transition.account(s.budget, nil, job)
          :ok = Projection.replace(s.projection, nil, job)

          next = %{
            s
            | budget: budget,
              next_sequence: s.next_sequence + 1,
              segment: %{
                id: receipt.segment_id,
                state: :active,
                bytes: receipt.offset + byte_size(payload) + 28,
                count: if(receipt.segment_id == s.segment.id, do: s.segment.count + 1, else: 1)
              },
              blocked:
                s.blocked + if(Map.has_key?(c.queues, definition["queue_key"]), do: 0, else: 1)
          }

          hook(c, :post_projection)
          {{:ok, view(next, job)}, next}

        {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
          failure(s, :capacity, reason, raw)

        _ ->
          exit(:writer_commit_unknown)
      end
    else
      {:error, {:resource_limit, key}} ->
        failure(s, :capacity, key, raw)

      {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
        failure(s, :capacity, reason, raw)

      {:error, _} ->
        failure(s, :invalid, :insertion_validation, raw)
    end
  end

  defp expected_position(s, payload_bytes) do
    rotate =
      s.segment.count > 0 and
        (s.segment.state == :sealed or
           s.segment.bytes + payload_bytes + 28 + 64 > s.config.rotation_target_bytes)

    %{
      sequence: s.next_sequence,
      segment_id: s.segment.id + if(rotate, do: 1, else: 0),
      offset: if(rotate, do: 44, else: s.segment.bytes)
    }
  end

  defp headroom(s, bytes) do
    cond do
      s.next_sequence > Segment.max_id() -> {:error, :sequence_exhausted}
      expected_position(s, bytes).segment_id > Segment.max_id() -> {:error, :segment_id_exhausted}
      true -> :ok
    end
  end

  defp failure(s, kind, reason, raw),
    do: {{:error, Error.new(kind, reason, JobID.encode(raw), :insert)}, s}

  defp view(s, job),
    do: Job.view(job, s.config.workers, s.config.queues, s.store_id, s.generation)

  defp snapshot(s),
    do: %{
      jobs: s.budget.count,
      blocked_jobs: s.blocked,
      state_bytes_charged: s.budget.bytes,
      state_nodes_charged: s.budget.nodes,
      startup_state_bytes_budget: 3 * s.config.max_state_bytes,
      insertion_space: if(s.next_sequence > Segment.max_id(), do: :exhausted, else: :available)
    }

  defp startup_error(%Tay.Storage.Recovery.Error{} = error),
    do: Error.new(:unavailable, {:recovery, error})

  defp startup_error(_), do: Error.new(:unavailable, :recovery_failed)

  defp hook(c, point) do
    if @test and is_function(Map.get(c, :test_hook), 1), do: c.test_hook.(point)
    :ok
  end

  def terminate(_, s) do
    if Process.alive?(s.writer), do: GenServer.stop(s.writer, :normal, :infinity)
    :ok
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_engine)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :generation_failed)
end
