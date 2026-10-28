defmodule Tay.Executor.SocketPathTest do
  use ExUnit.Case, async: true

  alias Tay.Executor.SocketPath

  defp resolve(setting, env, uid \\ 4_242) do
    SocketPath.resolve(setting,
      env: env,
      directory_exists: fn _ -> false end,
      uid: uid,
      usable_directory: fn _path, _uid -> true end
    )
  end

  test "Elixir follows the shared SDK discovery contract" do
    fixtures =
      Path.expand("../../../clients/python/tests/fixtures/socket_discovery.json", __DIR__)

    for fixture <- fixtures |> File.read!() |> Jason.decode!() do
      setting = if fixture["setting"] == "auto", do: :auto, else: fixture["setting"]

      result =
        SocketPath.resolve(setting,
          env: fixture["env"],
          uid: Map.get(fixture, "uid", 4242),
          directory_exists: &(&1 in fixture["directories"]),
          usable_directory: fn path, _ -> path in fixture["usable"] end
        )

      if fixture["error"] do
        assert {:error, _} = result, fixture["name"]
      else
        assert {:ok, %{path: path, private_directory: private}} = result, fixture["name"]
        assert path == fixture["path"], fixture["name"]
        assert private == fixture["private"], fixture["name"]
      end
    end
  end

  test "shared runtime directory is selected before the socket exists and is caller-owned" do
    options = [
      env: %{"XDG_RUNTIME_DIR" => "/runtime"},
      uid: 4242,
      directory_exists: fn path -> path == "/run/tay" end
    ]

    assert {:ok, %{path: "/run/tay/tay.sock", private_directory: false, source: :shared_runtime}} =
             SocketPath.resolve(:auto, options)

    assert {:ok, %{path: "/override.sock", source: :explicit}} =
             SocketPath.resolve("/override.sock", options)

    assert {:ok, %{path: "/env.sock", source: :environment}} =
             SocketPath.resolve(
               :auto,
               Keyword.put(options, :env, %{"TAY_SOCKET_PATH" => "/env.sock"})
             )
  end

  test "explicit path wins over environment discovery" do
    assert {:ok, %{path: "/chosen/tay.sock", private_directory: false, source: :explicit}} =
             resolve("/chosen/tay.sock", %{"TAY_SOCKET_PATH" => "/environment/tay.sock"})
  end

  test "TAY_SOCKET_PATH wins over automatic locations" do
    assert {:ok, %{path: "/environment/tay.sock", private_directory: false, source: :environment}} =
             resolve(:auto, %{
               "TAY_SOCKET_PATH" => "/environment/tay.sock",
               "XDG_RUNTIME_DIR" => "/runtime",
               "TMPDIR" => "/temporary"
             })
  end

  test "automatic discovery prefers XDG then TMPDIR then a per-UID tmp fallback" do
    assert {:ok, %{path: "/runtime/tay/tay.sock", private_directory: true, source: :xdg_runtime}} =
             resolve(:auto, %{"XDG_RUNTIME_DIR" => "/runtime", "TMPDIR" => "/temporary"})

    assert {:ok,
            %{path: "/temporary/tay-4242/tay.sock", private_directory: true, source: :tmpdir}} =
             resolve(:auto, %{"TMPDIR" => "/temporary"})

    assert {:ok, %{path: "/tmp/tay-4242/tay.sock", private_directory: true, source: :tmp}} =
             resolve(:auto, %{})
  end

  test "automatic fallback is isolated by Unix UID and nil is an explicit opt-out" do
    assert {:ok, %{path: first}} = resolve(:auto, %{}, 101)
    assert {:ok, %{path: second}} = resolve(:auto, %{}, 202)
    refute first == second

    assert {:ok, %{path: nil, private_directory: false, source: :disabled}} = resolve(nil, %{})
  end

  test "invalid explicit or environment paths are refused rather than silently replaced" do
    assert {:error, :invalid_socket_path} = resolve("relative.sock", %{})

    assert {:error, :invalid_socket_path} =
             resolve(:auto, %{"TAY_SOCKET_PATH" => "relative.sock"})

    assert {:error, :invalid_socket_path} =
             resolve(:auto, %{"TAY_SOCKET_PATH" => "/" <> String.duplicate("x", 101)})
  end

  test "disabled sockets do not require a UID or directory inspection" do
    assert {:ok, %{path: nil, source: :disabled}} =
             SocketPath.resolve(nil,
               env: %{},
               uid: -1,
               directory_exists: fn _ -> flunk("directory inspected") end,
               usable_directory: fn _, _ -> flunk("directory inspected") end
             )
  end
end
