defmodule Tay.HTTP.APITest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  test "remote HTTP worker executes a job without a Unix socket" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    ExecutionHelpers.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:ok, root} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: nil,
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

    assert ExecutionHelpers.eventually(fn ->
             case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 100) do
               {:ok, connection} ->
                 :gen_tcp.close(connection)
                 true

               _ ->
                 false
             end
           end)

    assert {201, %{"worker_token" => token}} =
             request(:post, base <> "/workers", %{
               runtime_id: "remote-test",
               tasks: ["tests.remote.v1"],
               capacity: 1
             })

    assert {401, %{"error" => %{"code" => "unauthorized"}}} =
             request(:post, base <> "/queues/default/claim")

    auth = ["Authorization: Bearer " <> token]

    assert {409, %{"error" => %{"code" => "wrong_queue"}}} =
             request(:post, base <> "/queues/other/claim", nil, auth)

    claim = Task.async(fn -> request(:post, base <> "/queues/default/claim", nil, auth) end)

    assert {201, %{"job_id" => id}} =
             request(:post, base <> "/jobs", %{
               task: "tests.remote.v1",
               args: %{"value" => 3},
               options: %{}
             })

    assert {200,
            %{
              "type" => "execute",
              "job_id" => ^id,
              "reservation_id" => reservation,
              "execution_id" => execution
            }} = Task.await(claim, 8_000)

    context = %{reservation_id: reservation, execution_id: execution}

    assert {200, %{"type" => "accepted"}} =
             request(:post, base <> "/workers/started", context, auth)

    assert {200, %{"type" => "accepted"}} =
             request(
               :post,
               base <> "/workers/complete",
               Map.merge(context, %{outcome: "success", result: %{"answer" => 6}}),
               auth
             )

    assert ExecutionHelpers.eventually(fn ->
             match?({200, %{"status" => "completed"}}, request(:get, base <> "/jobs/" <> id))
           end)

    assert {200, %{"result" => %{"answer" => 6}}} =
             request(:get, base <> "/jobs/" <> id <> "/result")

    python = System.find_executable("python3.12") || System.find_executable("python3.11")

    script = """
    import asyncio
    import contextlib
    import sys
    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import TayHTTP, TayHTTPWorker

    async def main():
        worker = TayHTTPWorker(sys.argv[1])
        @worker.task(name="tests.python.remote.v1")
        def double(value):
            return {"answer": value * 2}
        await worker.register()
        runner = asyncio.create_task(worker.serve_forever())
        try:
            async with TayHTTP(sys.argv[1]) as producer:
                job = await producer.enqueue("tests.python.remote.v1", {"value": 4})
                for _ in range(100):
                    if await job.status() == "completed":
                        assert await job.result() == {"answer": 8}
                        return
                    await asyncio.sleep(0.02)
                raise AssertionError("remote worker did not complete the job")
        finally:
            runner.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await runner
            await worker.close()

    asyncio.run(main())
    """

    assert {"", 0} = System.cmd(python, ["-c", script, base], stderr_to_stdout: true)

    assert {201, %{"worker_token" => lost_token}} =
             request(:post, base <> "/workers", %{
               runtime_id: "lost-worker",
               tasks: ["tests.lost.v1"],
               capacity: 1
             })

    lost_auth = ["Authorization: Bearer " <> lost_token]

    assert {201, %{"job_id" => lost_id}} =
             request(:post, base <> "/jobs", %{
               task: "tests.lost.v1",
               args: %{},
               options: %{retries: 1}
             })

    assert {200, %{"type" => "execute", "job_id" => ^lost_id}} =
             request(:post, base <> "/queues/default/claim", nil, lost_auth)

    assert {200, %{"type" => "closed"}} =
             request(:delete, base <> "/workers", nil, lost_auth)

    assert ExecutionHelpers.eventually(fn ->
             case request(:get, base <> "/jobs/" <> lost_id) do
               {200, %{"status" => state}} when state in ["retryable", "ready", "discarded"] ->
                 true

               _ ->
                 false
             end
           end)

    assert {201, %{"worker_token" => cancel_token}} =
             request(:post, base <> "/workers", %{
               runtime_id: "cancel-worker",
               tasks: ["tests.cancel.v1"],
               capacity: 1
             })

    cancel_auth = ["Authorization: Bearer " <> cancel_token]

    assert {201, %{"job_id" => cancel_id}} =
             request(:post, base <> "/jobs", %{
               task: "tests.cancel.v1",
               args: %{},
               options: %{}
             })

    assert {200, %{"type" => "execute", "job_id" => ^cancel_id}} =
             request(:post, base <> "/queues/default/claim", nil, cancel_auth)

    assert {200, %{"type" => "cancelled"}} =
             request(:delete, base <> "/jobs/" <> cancel_id)

    assert {200, %{"type" => "cancel_execution"}} =
             request(:post, base <> "/queues/default/claim", nil, cancel_auth)
  end

  test "enqueue preserves an admission refusal's machine-readable reason" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    ExecutionHelpers.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:ok, root} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: nil,
               http_port: port,
               max_jobs: 0
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    base = "http://127.0.0.1:#{port}"

    assert ExecutionHelpers.eventually(fn ->
             case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 100) do
               {:ok, connection} ->
                 :gen_tcp.close(connection)
                 true

               _ ->
                 false
             end
           end)

    assert {429, %{"error" => %{"code" => "capacity", "reason" => "retained_jobs"}}} =
             request(:post, base <> "/jobs", %{
               task: "tests.remote.v1",
               args: %{},
               options: %{}
             })
  end

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

    assert ExecutionHelpers.eventually(fn ->
             case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 100) do
               {:ok, connection} ->
                 :gen_tcp.close(connection)
                 true

               _ ->
                 false
             end
           end)

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

  defp request(method, url, payload \\ nil, headers \\ []) do
    args = ["-sS", "--max-time", "5", "-X", method |> Atom.to_string() |> String.upcase()]
    args = args ++ Enum.flat_map(headers, &["-H", &1])

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

    python = System.find_executable("python3.12") || System.find_executable("python3.11")

    script = """
    import asyncio
    import sys
    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import ServerError, TayHTTP

    async def main():
        async with TayHTTP(
            sys.argv[1],
            tls_ca_file=sys.argv[2],
            tls_cert_file=sys.argv[3],
            tls_key_file=sys.argv[4],
        ) as tay:
            try:
                await tay._request("GET", "/unknown")
            except ServerError as error:
                assert error.code == "not_found"
            else:
                raise AssertionError("mTLS request unexpectedly succeeded without an API error")

    asyncio.run(main())
    """

    assert {"", 0} =
             System.cmd(
               python,
               ["-c", script, "https://127.0.0.1:#{port}", ca, client_cert, client_key],
               stderr_to_stdout: true
             )

    {_output, status} =
      System.cmd("curl", ["-sS", "--cacert", ca, "--max-time", "5", url], stderr_to_stdout: true)

    refute status == 0
  end
end
