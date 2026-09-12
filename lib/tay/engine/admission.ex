defmodule Tay.Engine.Admission do
  @moduledoc """
  Fixed-slot, fixed-byte-quota cooperative client admission. No payload is sent
  before a monitored reservation is granted. Submitted slots outlive callers.
  The public ETS table holds only reservation/status metadata, never job state.
  It is not a security boundary against hostile code in the same VM.
  """
  alias Tay.Error

  def metadata(name) do
    case :ets.lookup(name, :meta) do
      [{:meta, meta}] -> {:ok, meta}
      _ -> {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def status(name) do
    with {:ok, m} <- metadata(name) do
      used =
        Enum.count(1..m.slots, fn slot ->
          case :ets.lookup(name, slot) do
            [{_, nil, nil, :free, _}] -> false
            _ -> true
          end
        end)

      {:ok,
       Map.merge(m.status, %{
         client_slots: m.slots,
         client_slots_used: used,
         client_byte_capacity: m.slots * m.slot_bytes,
         slot_byte_limit: m.slot_bytes,
         freshness: :bounded_snapshot
       })}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def request(name, meta, payload, bytes, operation, id, timeout) do
    with true <- bytes <= meta.slot_bytes || {:error, :client_bytes},
         {:ok, permit} <- claim(name, meta, timeout) do
      try do
        case GenServer.call(meta.guardian, {:reserve, meta.generation, permit}, timeout) do
          :ok -> submit(meta, permit, payload, operation, id, timeout)
          {:error, reason} -> {:error, Error.new(:unavailable, reason, id, operation)}
        end
      catch
        :exit, _ -> {:error, Error.new(:unavailable, :reservation_lost, id, operation)}
      after
        send(meta.guardian, {:cancel_reservation, self(), permit})
      end
    else
      {:error, reason} -> {:error, Error.new(:capacity, reason, id, operation)}
    end
  end

  defp submit(meta, permit, payload, operation, id, timeout) do
    try do
      GenServer.call(meta.guardian, {:submit, meta.generation, permit, payload}, timeout)
    catch
      :exit, _ ->
        kind = if operation == :insert, do: :unknown_outcome, else: :unavailable
        {:error, Error.new(kind, :submitted_request_lost, id, operation)}
    end
  end

  # Claim is bounded by configured slot count; there is no waiting queue.
  def claim(name, meta, timeout) do
    token = make_ref()
    expires = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(1..meta.slots, {:error, :client_slots}, fn slot, _ ->
      replacement = {slot, token, self(), :claimed, expires}

      if cas(name, {slot, nil, nil, :free, 0}, replacement),
        do: {:halt, {:ok, {slot, token}}},
        else: {:cont, {:error, :client_slots}}
    end)
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def cas(table, previous, next),
    do: :ets.select_replace(table, [{previous, [], [{:const, next}]}]) == 1
end
