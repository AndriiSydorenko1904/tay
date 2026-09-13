defmodule Tay.Executor.SocketPathTest do
  use ExUnit.Case, async: true

  alias Tay.Executor.SocketPath

  defp resolve(setting, env, uid \\ 4_242) do
    SocketPath.resolve(setting,
      env: env,
      uid: uid,
      usable_directory: fn _path, _uid -> true end
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
end
