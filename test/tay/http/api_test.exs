defmodule Tay.HTTP.APITest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  test "Bandit serves producer operations as bounded JSON" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    socket = Path.join(Path.dirname(path), "http-#{System.unique_integer([:positive])}.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    assert {:ok, root} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: socket,
               http_port: port,
               execution_wake_ms: 5
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    base = "http://127.0.0.1:#{port}"

    assert {201, %{"job_id" => id, "type" => "enqueued"}} =
             request(:post, base <> "/jobs", %{
               task: "tests.http.v1",
               args: %{"value" => 1},
               options: %{}
             })

    assert {200, %{"type" => "status"}} = request(:get, base <> "/jobs/" <> id)

    assert {200, %{"type" => "cancelled"}} =
             request(:delete, base <> "/jobs/" <> id)

    assert {400, %{"error" => %{"code" => "invalid_enqueue"}}} =
             request(:post, base <> "/jobs", %{args: %{}})

    python = System.find_executable("python3.12") || System.find_executable("python3.11")

    script = """
    import asyncio
    import sys
    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import TayHTTP

    async def main():
        async with TayHTTP(sys.argv[1]) as tay:
            job = await tay.enqueue("tests.python.http.v1", {"value": 2})
            assert job.id
            assert isinstance(await job.status(), str)
            await job.cancel()

    asyncio.run(main())
    """

    assert {"", 0} = System.cmd(python, ["-c", script, base], stderr_to_stdout: true)
  end

  defp request(method, url, payload \\ nil) do
    args = ["-sS", "--max-time", "5", "-X", method |> Atom.to_string() |> String.upcase()]

    args =
      if payload,
        do:
          args ++
            [
              "-H",
              "Content-Type: application/json",
              "-d",
              :json.encode(payload) |> IO.iodata_to_binary()
            ],
        else: args

    {body, 0} = System.cmd("curl", args ++ ["-w", "\n%{http_code}", url])
    [json, status] = String.split(body, "\n", parts: 2)
    {String.to_integer(status), :json.decode(json)}
  end

  test "HTTPS listener requires a trusted client certificate" do
    directory = NativeHelpers.path()
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    ca = Path.join(directory, "ca.pem")
    ca_key = Path.join(directory, "ca.key")
    cert = Path.join(directory, "server.pem")
    key = Path.join(directory, "server.key")
    client_cert = Path.join(directory, "client.pem")
    client_key = Path.join(directory, "client.key")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=Tay test CA",
          "-keyout",
          ca_key,
          "-out",
          ca
        ],
        stderr_to_stdout: true
      )

    for {name, leaf_cert, leaf_key} <- [
          {"server", cert, key},
          {"client", client_cert, client_key}
        ] do
      csr = Path.join(directory, "#{name}.csr")
      subject = if name == "server", do: "/CN=127.0.0.1", else: "/CN=tay-client"

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            subject,
            "-keyout",
            leaf_key,
            "-out",
            csr
          ],
          stderr_to_stdout: true
        )

      extension = Path.join(directory, "#{name}.ext")

      File.write!(
        extension,
        if(name == "server",
          do: "subjectAltName=IP:127.0.0.1\n",
          else: "extendedKeyUsage=clientAuth\n"
        )
      )

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "x509",
            "-req",
            "-in",
            csr,
            "-CA",
            ca,
            "-CAkey",
            ca_key,
            "-CAcreateserial",
            "-days",
            "1",
            "-out",
            leaf_cert,
            "-extfile",
            extension
          ],
          stderr_to_stdout: true
        )
    end

    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, listener} =
      Tay.HTTP.Listener.start_link(%{
        engine_name: __MODULE__,
        executor_server: self(),
        port: port,
        ip: "127.0.0.1",
        max_body_bytes: 1_048_576,
        tls_certfile: cert,
        tls_keyfile: key,
        tls_cacertfile: ca
      })

    on_exit(fn ->
      try do
        if Process.alive?(listener), do: GenServer.stop(listener)
      catch
        :exit, _ -> :ok
      end
    end)

    url = "https://127.0.0.1:#{port}/unknown"

    {body, 0} =
      System.cmd(
        "curl",
        [
          "-sS",
          "--cacert",
          ca,
          "--cert",
          client_cert,
          "--key",
          client_key,
          "--max-time",
          "5",
          url
        ],
        stderr_to_stdout: true
      )

    assert %{"error" => %{"code" => "not_found"}} = :json.decode(body)

    {_output, status} =
      System.cmd("curl", ["-sS", "--cacert", ca, "--max-time", "5", url], stderr_to_stdout: true)

    refute status == 0
  end
end
