# Tay Python SDK

`tay` is the stdlib-only Protocol v1 producer and worker client for a local Tay
Unix-domain socket. `Tay()` needs no socket setting: it uses the same discovery
contract as the Elixir Engine (explicit path, `TAY_SOCKET_PATH`, XDG runtime,
`TMPDIR`, then `/tmp/tay-<uid>`). It is intentionally a separately installable
package:

```sh
python -m pip install ./clients/python
```

Create a `Tay(mode="client")` producer, or a `Tay(mode="worker")` process that
only executes registered tasks. The SDK sends JSON-object arguments and bounded
JSON results; it does not serialize arbitrary Python objects.

Run a dedicated worker module with:

```sh
tay-worker myapp.jobs
```

The imported module must create exactly one `Tay(mode="worker")` instance and
register its tasks. Pass `socket_path=` or set `TAY_SOCKET_PATH` only to override
automatic discovery. See the repository README for the current durable-result/
scheduling compatibility boundary.
