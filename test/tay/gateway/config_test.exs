defmodule Tay.Gateway.ConfigTest do
  use ExUnit.Case, async: true

  alias Tay.Gateway.Config

  test "HTTP and socket environment use one transport selection policy" do
    for {setting, http_port, environment, expected} <- [
          {:auto, nil, %{}, "/tmp/tay-4242/tay.sock"},
          {:auto, 8080, %{}, nil},
          {:auto, 8080, %{"TAY_SOCKET_PATH" => ""}, nil},
          {:auto, 8080, %{"TAY_SOCKET_PATH" => "/env.sock"}, "/env.sock"},
          {:auto, nil, %{"TAY_SOCKET_PATH" => "off"}, nil},
          {:auto, 8080, %{"TAY_SOCKET_PATH" => "off"}, nil},
          {nil, 8080, %{"TAY_SOCKET_PATH" => "/env.sock"}, nil},
          {"/explicit.sock", 8080, %{"TAY_SOCKET_PATH" => "off"}, "/explicit.sock"}
        ] do
      assert {:ok, %{path: ^expected}} =
               Config.resolve_socket(setting, http_port,
                 env: environment,
                 uid: 4242,
                 directory_exists: fn _ -> false end,
                 usable_directory: fn _, _ -> true end
               )
    end

    assert {:error, :invalid_socket_path} =
             Config.resolve_socket(:auto, 8080, env: %{"TAY_SOCKET_PATH" => "relative.sock"})
  end

  test "frozen socket handoff preserves the chosen path and private directory policy" do
    alias Tay.Executor.SocketPath

    assert {:ok, resolved} =
             SocketPath.resolve(:auto,
               env: %{"XDG_RUNTIME_DIR" => "/chosen-runtime"},
               uid: 4242,
               directory_exists: fn _ -> false end,
               usable_directory: fn _, _ -> true end
             )

    frozen = SocketPath.freeze(resolved)

    assert {:ok, ^frozen} =
             Config.resolve_socket(frozen, 8080, env: %{"TAY_SOCKET_PATH" => "off"}, uid: -1)

    assert frozen.path == "/chosen-runtime/tay/tay.sock"
    assert frozen.private_directory

    assert {:error, :invalid_socket_path} =
             Config.resolve_socket(%{frozen | path: "relative.sock"}, nil)
  end

  test "HTTP validation covers addressing, TLS paths and transport combinations" do
    base = Config.defaults()

    for {changes, result} <- [
          {%{http_port: 8080}, :ok},
          {%{http_port: 8080, http_ip: "::1"}, :ok},
          {%{http_port: 8080, http_ip: "0.0.0.0"}, {:error, :http_tls_required}},
          {%{http_port: 0}, {:error, :invalid_http_port}},
          {%{http_ip: "invalid"}, {:error, :invalid_http_ip}},
          {%{http_tls_certfile: "/cert"}, {:error, :invalid_http_tls_paths}},
          {%{http_tls_certfile: "/cert", http_tls_keyfile: "/key", http_tls_cacertfile: "/ca"},
           {:error, :http_port_required}}
        ] do
      assert Config.validate_http(Map.merge(base, changes)) == result
    end
  end
end
