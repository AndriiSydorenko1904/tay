defmodule Tay.JobID do
  @moduledoc "Stable 128-bit random job identity; never a storage sequence or clock."
  def new do
    case :crypto.strong_rand_bytes(16) do
      <<0::128>> -> new()
      id -> encode(id)
    end
  end

  def encode(id) when is_binary(id) and byte_size(id) == 16 and id != <<0::128>>,
    do: Base.encode16(id, case: :lower)

  def decode(id) when is_binary(id) and byte_size(id) == 32 do
    case Base.decode16(id, case: :lower) do
      {:ok, <<0::128>>} -> {:error, :invalid_job_id}
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_job_id}
    end
  end

  def decode(_), do: {:error, :invalid_job_id}
end
