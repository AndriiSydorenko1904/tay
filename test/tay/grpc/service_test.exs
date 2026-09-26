defmodule Tay.GRPC.ServiceTest do
  use ExUnit.Case, async: false

  alias Tay.GRPC.Service
  alias Tay.Grpc.V1.{EnqueueRequest, JobRequest}
  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    root = Path.join(System.tmp_dir!(), "tay-grpc-#{System.unique_integer([:positive])}")
    socket = Path.join(root, "executor.sock")
    :ok = File.mkdir_p(root)
    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(path)
    end)

    %{path: path, socket: socket}
  end

  test "gRPC producer methods use the same Engine semantics as Protocol v1", %{
    path: path,
    socket: socket
  } do
    port = unused_port()

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               grpc_port: port,
               execution_wake_ms: 5
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert ExecutionHelpers.eventually(fn ->
             case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
               {:ok, client} ->
                 :ok = :gen_tcp.close(client)
                 true

               {:error, _} ->
                 false
             end
           end)

    request = %EnqueueRequest{
      task: "grpc.producer.v1",
      args_json: ~s({"invoice_id":"inv-42"}),
      options_json: ~s({"submission_id":"grpc-service-test"})
    }

    reply = Service.enqueue(request, nil)

    assert %{
             "type" => "enqueued",
             "job_id" => id,
             "job" => %{"args" => %{"invoice_id" => "inv-42"}}
           } =
             :json.decode(reply.json)

    status = Service.get_job(%JobRequest{job_id: id}, nil)
    assert %{"type" => "status", "status" => "available"} = :json.decode(status.json)

    cancelled = Service.cancel(%JobRequest{job_id: id}, nil)
    assert %{"type" => "cancelled", "status" => "cancelled"} = :json.decode(cancelled.json)
  end

  test "mTLS listener accepts trusted clients and rejects missing or untrusted certificates", %{
    path: path,
    socket: socket
  } do
    certs = certificates(Path.dirname(socket))
    port = unused_port()

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               grpc_port: port,
               grpc_tls_certfile: certs.server_cert,
               grpc_tls_keyfile: certs.server_key,
               grpc_tls_cacertfile: certs.ca_cert
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert ExecutionHelpers.eventually(fn ->
             case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
               {:ok, client} ->
                 :ok = :gen_tcp.close(client)
                 true

               {:error, _} ->
                 false
             end
           end)

    common = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(certs.ca_cert),
      server_name_indication: ~c"localhost",
      versions: [:"tlsv1.2"],
      active: false
    ]

    assert {:ok, socket} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               common ++
                 [
                   certfile: String.to_charlist(certs.client_cert),
                   keyfile: String.to_charlist(certs.client_key)
                 ],
               5_000
             )

    :ok = :ssl.close(socket)

    assert {:error, _} = :ssl.connect({127, 0, 0, 1}, port, common, 5_000)

    assert {:error, _} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               common ++
                 [
                   certfile: String.to_charlist(certs.untrusted_cert),
                   keyfile: String.to_charlist(certs.untrusted_key)
                 ],
               5_000
             )

    if python_path = System.get_env("TAY_GRPC_PYTHONPATH") do
      bundle = Path.join(Path.dirname(certs.client_cert), "client.p12")

      openssl!(Path.dirname(bundle), [
        "pkcs12",
        "-export",
        "-inkey",
        certs.client_key,
        "-in",
        certs.client_cert,
        "-certfile",
        certs.ca_cert,
        "-out",
        bundle,
        "-passout",
        "pass:tay-test-password"
      ])

      script = """
      import asyncio
      import sys
      from tay import TayGrpc

      async def main():
          async with TayGrpc(
              f"127.0.0.1:{sys.argv[1]}",
              tls_ca_file=sys.argv[2],
              tls_cert_file=sys.argv[3],
              tls_key_file=sys.argv[4],
          ) as tay:
              job = await tay.enqueue("grpc.python.mtls.v1", {"value": 1})
              assert await job.status() == "available"
              assert await job.cancel() == "cancelled"

          async with TayGrpc(
              f"127.0.0.1:{sys.argv[1]}",
              tls_pkcs12_file=sys.argv[5],
              tls_pkcs12_password="tay-test-password",
          ) as tay:
              job = await tay.enqueue("grpc.python.pkcs12.v1", {"value": 2})
              assert await job.status() == "available"
              assert await job.cancel() == "cancelled"

      asyncio.run(main())
      """

      paths = Path.join([File.cwd!(), "clients/python"]) <> ":" <> python_path

      {output, status} =
        System.cmd(
          "python3.11",
          [
            "-c",
            script,
            to_string(port),
            certs.ca_cert,
            certs.client_cert,
            certs.client_key,
            bundle
          ],
          env: [{"PYTHONPATH", paths}],
          stderr_to_stdout: true
        )

      assert status == 0, output
    end
  end

  defp certificates(directory) do
    ca_cert = Path.join(directory, "ca.pem")
    ca_key = Path.join(directory, "ca.key")
    server_cert = Path.join(directory, "server.pem")
    server_key = Path.join(directory, "server.key")
    client_cert = Path.join(directory, "client.pem")
    client_key = Path.join(directory, "client.key")
    untrusted_cert = Path.join(directory, "untrusted.pem")
    untrusted_key = Path.join(directory, "untrusted.key")

    openssl!(directory, [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=Tay Test CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-keyout",
      ca_key,
      "-out",
      ca_cert
    ])

    for {name, cert, key} <- [
          {"localhost", server_cert, server_key},
          {"tay-test-client", client_cert, client_key}
        ] do
      csr = cert <> ".csr"
      extensions = cert <> ".ext"

      :ok =
        File.write!(
          extensions,
          if(name == "localhost",
            do: "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n",
            else: "extendedKeyUsage=clientAuth\n"
          )
        )

      openssl!(directory, [
        "req",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-subj",
        "/CN=#{name}",
        "-keyout",
        key,
        "-out",
        csr
      ])

      openssl!(directory, [
        "x509",
        "-req",
        "-in",
        csr,
        "-CA",
        ca_cert,
        "-CAkey",
        ca_key,
        "-CAcreateserial",
        "-out",
        cert,
        "-days",
        "1",
        "-extfile",
        extensions
      ])
    end

    openssl!(directory, [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=untrusted-client",
      "-keyout",
      untrusted_key,
      "-out",
      untrusted_cert
    ])

    %{
      ca_cert: ca_cert,
      server_cert: server_cert,
      server_key: server_key,
      client_cert: client_cert,
      client_key: client_key,
      untrusted_cert: untrusted_cert,
      untrusted_key: untrusted_key
    }
  end

  defp openssl!(directory, args) do
    {output, 0} = System.cmd("openssl", args, cd: directory, stderr_to_stdout: true)
    assert is_binary(output)
  end

  defp unused_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end
