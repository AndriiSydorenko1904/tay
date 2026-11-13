defmodule Tay.Storage.V2.ResultReference do
  @moduledoc false
  alias Tay.Storage.{Record, V2.CheckpointIndex}

  def cold(result), do: %{cold_result: true, job_revision: result.job_revision}

  def cool(candidate) do
    results = Map.new(candidate.results, fn {id, result} -> {id, cold(result)} end)

    old =
      Enum.reduce(candidate.results, 0, fn {_, result}, sum ->
        sum + Tay.State.Memory.result_bytes(result)
      end)

    new =
      Enum.reduce(results, 0, fn {_, result}, sum ->
        sum + Tay.State.Memory.result_bytes(result)
      end)

    %{
      candidate
      | results: results,
        bytes: candidate.bytes - old + new,
        auxiliary_bytes: candidate.auxiliary_bytes - old + new
    }
  end

  def track(
        locations,
        epoch,
        segment,
        offset,
        %{record_type: type, payload_schema_version: 2} = record
      )
      when type in [10, 14] do
    with {:ok, event, _} <-
           Tay.Event.decode_payload(type, 2, record.payload, Tay.Event.Value.defaults()) do
      pointer = CheckpointIndex.pointer(epoch, segment, offset, record)
      Map.put(locations, event.data["job_id"], pointer)
    else
      _ -> locations
    end
  end

  def track(locations, _, _, _, _), do: locations

  def written(state, <<"TAY", 0, 1, type, _::binary>> = frame, receipt) when type in [10, 14] do
    with {:ok, record, <<>>} <- Record.decode(frame) do
      Map.put(
        state,
        :result_locations,
        track(
          Map.get(state, :result_locations, %{}),
          state.epoch_id,
          receipt.segment_id,
          receipt.offset,
          record
        )
      )
    else
      _ -> state
    end
  end

  def written(state, _, _), do: state

  def fetch(state, id, revision) do
    result =
      case Map.fetch(Map.get(state, :result_locations, %{}), id) do
        {:ok, pointer} ->
          with {:ok, record} <-
                 CheckpointIndex.read_record(state.native, state.epoch_id, :epoch, pointer),
               {:ok, event, _} <-
                 Tay.Event.decode_payload(
                   record.record_type,
                   2,
                   record.payload,
                   state.value_limits
                 ),
               true <- event.data["job_id"] == id || {:error, :result_identity} do
            expected =
              event.data["expected_revision"] + if(record.record_type == 14, do: 1, else: 0)

            {:ok,
             %{value: event.data["result"], job_revision: expected, recorded_at: event.data["at"]}}
          end

        :error ->
          CheckpointIndex.result(state.native, state.result_checkpoint, state.epoch_id, id)
      end

    with {:ok, result} <- result,
         true <- result.job_revision == revision || {:error, :result_revision},
         do: {:ok, result.value}
  end
end
