{fixtures, _} = Code.eval_file(Path.join(__DIR__, "manifest.exs"))

for {name, hex} <- fixtures do
  path = Path.join(__DIR__, name)
  bytes = Base.decode16!(hex, case: :lower)

  case File.read(path) do
    {:ok, ^bytes} -> :ok
    {:ok, _} -> raise "Refusing to replace fixed fixture #{name}"
    {:error, :enoent} -> File.write!(path, bytes, [:exclusive, :binary])
    {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
  end
end

IO.puts("Verified/materialized #{length(fixtures)} permanent segment fixtures")
