Code.require_file("harness.exs", __DIR__)

{options, arguments, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      path: :string,
      output: :string,
      scenario: :string,
      mode: :string,
      validated_filesystem: :boolean,
      jobs: :integer,
      args_bytes: :integer,
      clients: :integer,
      client_slots: :integer,
      deadline_ms: :integer,
      rotation_segments: :integer,
      replay_segments: :string
    ]
  )

if invalid != [] or arguments != [], do: raise("unknown benchmark argument")

scenario =
  case Keyword.get(options, :scenario, "lifecycle") do
    "lifecycle" -> :lifecycle
    "rotation" -> :rotation
    "replay" -> :replay
    "schedule" -> :schedule
    "reserve" -> :reserve
    _ -> raise("scenario must be lifecycle, rotation, replay, schedule, or reserve")
  end

mode =
  case Keyword.get(options, :mode, "sync") do
    "sync" -> :sync
    "write" -> :write
    _ -> raise("mode must be explicit sync or write")
  end

config =
  options
  |> Keyword.drop([:output, :scenario, :replay_segments])
  |> Map.new()
  |> Map.put(:mode, mode)

config =
  if value = Keyword.get(options, :replay_segments),
    do:
      Map.put(
        config,
        :replay_segments,
        String.split(value, ",") |> Enum.map(&String.to_integer/1)
      ),
    else: config

result = Tay.Bench.Harness.run(scenario, config)
json = Tay.Bench.Stats.json(result)

case Keyword.get(options, :output) do
  nil -> IO.puts(json)
  path -> File.write!(path, json <> "\n", [:exclusive])
end
