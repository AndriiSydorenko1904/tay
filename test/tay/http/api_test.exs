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

    assert {200, %{"type" => "health", "state" => "ready"}} = request(:get, base <> "/health")

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

    assert {:ok, _} = Tay.compact(name: __MODULE__, timeout: 60_000)
    assert Tay.result(id, name: __MODULE__) == {:ok, %{"answer" => 6}}

    python = NativeHelpers.python!()

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

    EngineHelpers.stop(root)

    assert {:ok, restarted} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: nil,
               http_port: port,
               execution_wake_ms: 5
             )

    assert ExecutionHelpers.eventually(fn -> Tay.status(name: __MODULE__).state == :ready end)
    assert Tay.result(id, name: __MODULE__) == {:ok, %{"answer" => 6}}

    assert request(:get, base <> "/jobs/" <> id <> "/result") ==
             {200, %{"type" => "result", "result" => %{"answer" => 6}}}

    EngineHelpers.stop(restarted)
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
               max_state_bytes: 0
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

    assert {429, %{"error" => %{"code" => "capacity", "reason" => "retained_bytes"}}} =
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

    python = NativeHelpers.python!()

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

  test "HTTP and Unix SDK schedules share registration, inspection and cancellation" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    socket = path <> ".sock"
    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    {:ok, root} =
      ExecutionHelpers.start(path, __MODULE__,
        workers: %{},
        executor_socket: socket,
        http_port: port
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
               {:ok, conn} ->
                 :gen_tcp.close(conn)
                 true

               _ ->
                 false
             end
           end)

    assert {400, %{"error" => %{"code" => "invalid_schedule"}}} =
             request(:post, base <> "/schedules", %{
               task: "task.v1",
               every: %{seconds: 1},
               extra: true
             })

    assert {404, %{"error" => %{"code" => "schedule_not_found"}}} =
             request(:get, base <> "/schedules/missing")

    script = """
    import asyncio, sys, time
    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import Tay, TayHTTP
    async def main():
        uds = Tay(mode="client", socket_path=sys.argv[2])
        await uds.start()
        try:
            async with TayHTTP(sys.argv[1]) as http:
                start = int(time.time() * 1000) + 60000
                for client, key in [(http, "http-hourly"), (uds, "uds-hourly")]:
                    schedule = await client.every("tests.schedule.v1", hours=1,
                        declaration_id=key, overlap="queue", start_at=start)
                    current = await schedule.status()
                    assert current["overlap"] == "queue"
                    assert current["next_at"] == start
                    assert any(item["id"] == key for item in await http.schedules())
                    assert any(item["id"] == key for item in await uds.schedules())
                    assert (await http.get_schedule(key))["revision"] == current["revision"]
                    await schedule.cancel()
                    assert (await client.get_schedule(key))["cancelled_at"] is not None
                cron = await http.schedule("tests.schedule.v1", cron="0 8 * * *",
                    declaration_id="http-cron", overlap="skip")
                await cron.cancel()
        finally:
            await uds.close()
    asyncio.run(main())
    """

    assert {"", 0} =
             System.cmd(NativeHelpers.python!(), ["-c", script, base, socket],
               stderr_to_stdout: true
             )
  end

  test "HTTP completion retains its result when the common budget is full" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    ExecutionHelpers.initialize(path)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:ok, root} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: nil,
               http_port: port,
               execution_wake_ms: 5,
               max_state_bytes: 8_000_000
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(path)
    end)

    base = "http://127.0.0.1:#{port}"

    assert {201, %{"worker_token" => token}} =
             request(:post, base <> "/workers", %{
               runtime_id: "budget-worker",
               tasks: ["budget.v1"],
               capacity: 1
             })

    auth = ["Authorization: Bearer " <> token]
    claim = Task.async(fn -> request(:post, base <> "/queues/default/claim", nil, auth) end)

    assert {201, %{"job_id" => id}} =
             request(:post, base <> "/jobs", %{task: "budget.v1", args: %{}})

    assert {200, %{"reservation_id" => reservation, "execution_id" => execution}} =
             Task.await(claim, 8_000)

    context = %{reservation_id: reservation, execution_id: execution}
    assert {200, _} = request(:post, base <> "/workers/started", context, auth)
    {:ok, meta} = Tay.Engine.Admission.metadata(__MODULE__)
    remaining = meta.memory.limit - Tay.State.Memory.used(meta.memory)
    assert :ok = Tay.State.Memory.reserve(meta.memory, remaining)

    try do
      assert {200, _} =
               request(
                 :post,
                 base <> "/workers/complete",
                 Map.merge(context, %{
                   outcome: "success",
                   result: %{"blob" => String.duplicate("r", 60_000)}
                 }),
                 auth
               )

      assert ExecutionHelpers.eventually(fn ->
               match?({:ok, _}, Tay.result(id, name: __MODULE__))
             end)

      assert {:ok, %{"blob" => blob}} = Tay.result(id, name: __MODULE__)
      assert byte_size(blob) == 60_000
      assert Tay.status(name: __MODULE__).state == :ready
    after
      Tay.State.Memory.release(meta.memory, remaining)
    end

    assert {:ok, _} = Tay.compact(name: __MODULE__, timeout: 60_000)
    state = :sys.get_state(EngineHelpers.engine(root))
    assert Tay.State.Memory.used(state.memory) == state.budget.bytes + state.auxiliary_bytes
    assert {:ok, %{"blob" => retained}} = Tay.result(id, name: __MODULE__)
    assert byte_size(retained) == 60_000
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
    ca_config = Path.join(directory, "ca.cnf")

    # OpenSSL 1.1.1 can append -addext values to machine-default extensions,
    # producing duplicate CA extensions that make the issuer unusable.
    File.write!(ca_config, """
    [req]
    distinguished_name = dn
    x509_extensions = ca
    [dn]
    [ca]
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,keyCertSign,cRLSign
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid:always
    """)

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
          "-config",
          ca_config,
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
            "-config",
            ca_config,
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
        "basicConstraints=critical,CA:FALSE\n" <>
          "keyUsage=critical,digitalSignature,keyEncipherment\n" <>
          "subjectKeyIdentifier=hash\n" <>
          "authorityKeyIdentifier=keyid,issuer\n" <>
          if(name == "server",
            do: "extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n",
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

    {verification, verification_status} =
      System.cmd("openssl", ["verify", "-CAfile", ca, ca, cert, client_cert],
        stderr_to_stdout: true
      )

    assert verification_status == 0, verification

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

    untrusted_cert = Path.join(directory, "untrusted.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          Path.join(directory, "client.csr"),
          "-signkey",
          client_key,
          "-days",
          "1",
          "-out",
          untrusted_cert,
          "-extfile",
          Path.join(directory, "client.ext")
        ],
        stderr_to_stdout: true
      )

    # Explicit CA contexts exercise the same trust boundaries on both platforms.
    {output, status} =
      System.cmd(
        NativeHelpers.python!(),
        [
          Path.expand("test/support/https_probe.py"),
          Integer.to_string(port),
          ca,
          client_cert,
          client_key,
          untrusted_cert
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert output =~
             "mTLS: trusted client accepted; missing/untrusted clients, wrong CA and hostname rejected"
  end
end
