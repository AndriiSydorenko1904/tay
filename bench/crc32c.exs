# Run with: mix run --no-start bench/crc32c.exs
alias Tay.Storage.CRC32C
alias Tay.Storage.CRC32C.{Native, Reference}

unless Native.available?(), do: raise("CRC32C NIF must be loaded for this comparison")

IO.puts("CRC32C: median of 5 samples; same buffers, original Elixir vs portable C")

IO.puts(
  "#{System.version()} / OTP #{System.otp_release()} / #{:erlang.system_info(:system_architecture)}"
)

IO.puts("bytes\tElixir MiB/s\tC MiB/s\tspeedup")

for size <- [20, 256, 4096, 4097, 65_536, 1_048_576, 16_777_216] do
  bytes = binary_part(:binary.copy(<<0, 127, 128, 255>>, div(size + 3, 4)), 0, size)
  expected = Reference.checksum(bytes)
  ^expected = CRC32C.checksum(bytes)
  iterations = max(1, div(1_048_576, size))

  results =
    for module <- [Reference, CRC32C] do
      # Warm code and schedulers before timing; input construction is excluded.
      module.checksum(bytes)

      samples =
        for _ <- 1..5 do
          {microseconds, _} =
            :timer.tc(fn ->
              for _ <- 1..iterations, do: module.checksum(bytes)
            end)

          max(microseconds, 1)
        end

      elapsed = samples |> Enum.sort() |> Enum.at(2)
      size * iterations / 1_048_576 / (elapsed / 1_000_000)
    end

  [elixir, native] = results
  format = fn value -> :erlang.float_to_binary(value, decimals: 2) end
  IO.puts("#{size}\t#{format.(elixir)}\t#{format.(native)}\t#{format.(native / elixir)}x")
end
