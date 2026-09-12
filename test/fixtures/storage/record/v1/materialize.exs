# Maintenance-only mechanical hex-to-binary conversion; never run by tests.
# This script does not load Tay or compute a checksum, and never overwrites a fixture.
{fixtures, _binding} = Code.eval_file(Path.join(__DIR__, "manifest.exs"))

for fixture <- fixtures do
  bytes = Base.decode16!(fixture.hex)
  path = Path.join(__DIR__, fixture.file)

  case File.read(path) do
    {:ok, ^bytes} ->
      :ok

    {:ok, _different_bytes} ->
      raise "Refusing to overwrite compatibility fixture #{fixture.id}"

    {:error, :enoent} ->
      File.write!(path, bytes, [:binary, :exclusive])

    {:error, reason} ->
      raise File.Error, reason: reason, action: "read fixture", path: path
  end
end

IO.puts("Verified/materialized #{length(fixtures)} literal v1 binary fixtures; no codec invoked.")
