# Run with: mix run --no-start bench/record_crc32c.exs
defmodule Tay.Bench.RecordCRC32C do
  alias Tay.Storage.CRC32C

  def two_calls(header, payload) do
    state = CRC32C.update(CRC32C.initial(), header)
    {CRC32C.finalize(state), CRC32C.finalize(CRC32C.update(state, payload))}
  end

  def one_call(header, payload), do: CRC32C.record_checksums(header, payload)

  def median_ns(fun, header, payload, iterations) do
    fun.(header, payload)

    samples =
      for _ <- 1..5 do
        {microseconds, _} =
          :timer.tc(fn ->
            Enum.reduce(1..iterations, nil, fn _, _ -> fun.(header, payload) end)
          end)

        microseconds * 1000 / iterations
      end

    samples |> Enum.sort() |> Enum.at(2)
  end
end

alias Tay.Bench.RecordCRC32C, as: Bench
alias Tay.Storage.CRC32C.Native

unless Native.available?(), do: raise("CRC32C NIF must be loaded for this comparison")

IO.puts("Record CRC32C: median of 5 samples; two NIF calls vs one, same 20-byte header")

IO.puts(
  "#{System.version()} / OTP #{System.otp_release()} / #{:erlang.system_info(:system_architecture)}"
)

IO.puts("payload bytes\ttwo calls ns/record\tone call ns/record\tspeedup")

for size <- [0, 32, 256, 4095, 4096, 4097, 65_536, 1_048_576, 16_777_216] do
  payload = binary_part(:binary.copy(<<0, 127, 128, 255>>, div(size + 3, 4)), 0, size)
  header = <<"TAY", 0, 1, 1, 0, 1, 1::64, size::32>>
  expected = Bench.two_calls(header, payload)
  ^expected = Bench.one_call(header, payload)
  iterations = max(5, div(4_194_304, size + byte_size(header)))
  old = Bench.median_ns(&Bench.two_calls/2, header, payload, iterations)
  new = Bench.median_ns(&Bench.one_call/2, header, payload, iterations)
  format = fn n -> :erlang.float_to_binary(n, decimals: 2) end
  IO.puts("#{size}\t#{format.(old)}\t#{format.(new)}\t#{format.(old / new)}x")
end
