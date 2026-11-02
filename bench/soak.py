"""Disposable Docker soak with real Python workers, recovery and cold copies."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import shutil
import signal
import subprocess
import time
import uuid
from pathlib import Path


def command(*args: str, timeout: int = 180) -> str:
    result = subprocess.run(
        args, text=True, capture_output=True, timeout=timeout, check=False
    )
    if result.returncode:
        raise RuntimeError(f"{args[0:3]} failed: {result.stderr[-4000:]}")
    return result.stdout.strip()


def emit(value: dict) -> None:
    print("TAY_SOAK_JSON=" + json.dumps(value), flush=True)


def decoded(output: str) -> dict:
    for line in reversed(output.splitlines()):
        if line.startswith("TAY_SOAK_JSON="):
            return json.loads(line.split("=", 1)[1])
    raise RuntimeError(f"missing soak result: {output[-2000:]}")


async def worker(transport: str) -> None:
    from tay import Tay, TayHTTPWorker
    from tay.__main__ import _serve

    client = (
        Tay(mode="worker", socket_path="/run/tay/tay.sock", capacity=4)
        if transport == "uds"
        else TayHTTPWorker("http://127.0.0.1:8080", capacity=4)
    )
    failed: set[str] = set()
    observed = False

    @client.task(name="soak.echo.v1")
    async def echo(token: str, fail_once: bool = False, pause: float = 0) -> dict:
        nonlocal observed
        if not observed:
            emit({"worker_transport": transport, "executed": True})
            observed = True
        if fail_once and token not in failed:
            failed.add(token)
            raise RuntimeError("intentional soak retry")
        await asyncio.sleep(pause)
        failed.discard(token)
        return {"token": token}

    await _serve(client)


async def producer(action: str, state: dict) -> None:
    from tay import HTTPJobHandle, JobHandle, Tay, TayHTTP
    from tay.errors import ServerError

    async def exercise(transport: str) -> dict:
        client = (
            Tay(mode="client", socket_path="/run/tay/tay.sock")
            if transport == "uds"
            else TayHTTP("http://127.0.0.1:8080")
        )

        def handle(job_id: str):
            return (
                JobHandle(job_id, client)
                if transport == "uds"
                else HTTPJobHandle(job_id, client)
            )

        async with client:
            if action == "register":
                schedule = await client.every(
                    "soak.echo.v1",
                    seconds=1,
                    args={"token": transport},
                    declaration_id=f"soak-{transport}",
                    overlap="skip",
                )
                return {"schedule": schedule.id}
            if action == "seed":
                jobs = {}
                for durability in ("persistent", "volatile"):
                    token = uuid.uuid4().hex
                    job = await client.enqueue(
                        "soak.echo.v1",
                        {"token": token, "pause": 3},
                        submission_id=token,
                        durability=durability,
                        retries=5,
                    )
                    jobs[durability] = {"id": job.id, "token": token}
                # Kill/restart only after a durable execution actually started.
                for _ in range(100):
                    status = await handle(jobs["persistent"]["id"]).status()
                    if status == "executing" or (
                        isinstance(status, dict) and status.get("state") == "executing"
                    ):
                        return jobs
                    await asyncio.sleep(0.1)
                raise RuntimeError("recovery probe never started")
            if action == "verify":
                saved = state[transport]
                durable = handle(saved["persistent"]["id"])
                assert await durable.wait_result(timeout=60) == {
                    "token": saved["persistent"]["token"]
                }
                try:
                    await handle(saved["volatile"]["id"]).status()
                except ServerError as exc:
                    if exc.code != "not_found":
                        raise
                else:
                    raise RuntimeError("volatile job survived Engine replacement")
                witness = saved["witness"]
                assert await handle(witness["id"]).result() == {
                    "token": witness["token"]
                }
                for _ in range(100):
                    schedule = await client.get_schedule(f"soak-{transport}")
                    if (
                        schedule["last_at"] is not None
                        and schedule["last_at"] > saved["schedule_last_at"]
                    ):
                        break
                    await asyncio.sleep(0.1)
                else:
                    raise RuntimeError("durable schedule did not advance after restore")
                return {"recovered": True, "schedule_last_at": schedule["last_at"]}

            async def job(index: int) -> dict:
                token = uuid.uuid4().hex
                before = time.monotonic()
                handle = await client.enqueue(
                    "soak.echo.v1",
                    {"token": token, "fail_once": index % 4 == 0},
                    submission_id=token,
                    retries=3,
                    durability="volatile" if index % 4 == 3 else "persistent",
                )
                assert await handle.wait_result(timeout=60) == {"token": token}
                return {
                    "id": handle.id,
                    "token": token,
                    "elapsed_ms": (time.monotonic() - before) * 1000,
                }

            jobs = await asyncio.gather(*(job(i) for i in range(8)))
            schedule = await client.get_schedule(f"soak-{transport}")
            return {
                "jobs": len(jobs),
                "witness": jobs[1],
                "max_completion_ms": max(j["elapsed_ms"] for j in jobs),
                "schedule_last_at": schedule["last_at"],
            }

    results = await asyncio.gather(*(exercise(t) for t in ("uds", "http")))
    emit(dict(zip(("uds", "http"), results)))


class Soak:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.prefix = "tay-soak-" + uuid.uuid4().hex[:10]
        self.server = self.prefix + "-engine"
        self.workers = [self.prefix + "-" + t for t in ("uds", "http")]
        self.data = self.prefix + "-data"
        self.socket = self.prefix + "-socket"
        self.store = "/var/lib/tay/store"
        self.events = self.output / "events.jsonl"
        self.report = {
            "status": "starting",
            "started_at": time.time(),
            "cycles": 0,
            "completed_jobs": 0,
            "maintenance_cycles": 0,
            "duration_seconds": args.seconds,
            "controller_pid": os.getpid(),
            "data_volume": self.data,
            "socket_volume": self.socket,
            "engine_container": self.server,
            "worker_containers": self.workers,
            "notes": "Synthetic Docker-VM evidence; not production-device or power-loss certification.",
        }

    def save(self) -> None:
        self.report["updated_at"] = time.time()
        self.report["store"] = self.store
        pending = self.output / "report.pending"
        pending.write_text(json.dumps(self.report, indent=2) + "\n")
        pending.replace(self.output / "report.json")

    def event(self, kind: str, **values) -> None:
        with self.events.open("a") as stream:
            stream.write(
                json.dumps({"at": time.time(), "event": kind, **values}) + "\n"
            )
        print(kind, json.dumps(values), flush=True)

    def mounts(self) -> list[str]:
        return [
            "-v",
            f"{self.socket}:/run/tay",
            "-v",
            f"{self.output / 'snapshot'}:/soak:ro",
            "-e",
            "PYTHONPATH=/soak/sdk",
        ]

    def start_engine(self) -> None:
        command(
            "docker",
            "run",
            "-d",
            "--name",
            self.server,
            "--network",
            "none",
            "--memory",
            "512m",
            "--cpus",
            "2",
            "--read-only",
            "--tmpfs",
            "/tmp:rw,nosuid,size=64m,uid=10001,gid=10001,mode=0700",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "-v",
            f"{self.data}:/var/lib/tay",
            "-v",
            f"{self.socket}:/run/tay",
            "-e",
            f"TAY_DATA_DIR={self.store}",
            "-e",
            "TAY_INITIALIZE_IF_MISSING=true",
            "-e",
            "TAY_HTTP_PORT=8080",
            "-e",
            "TAY_HTTP_IP=127.0.0.1",
            "-e",
            "TAY_SOCKET_PATH=/run/tay/tay.sock",
            "-e",
            "TAY_CHECKPOINT_INTERVAL_MS=10000",
            "-e",
            "ERL_FLAGS=+S 2:2 +A 2",
            self.args.image,
        )
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            health = command(
                "docker", "inspect", "--format", "{{.State.Health.Status}}", self.server
            )
            if health == "healthy":
                return
            if health == "unhealthy":
                break
            time.sleep(1)
        raise RuntimeError("Engine failed readiness")

    def start_workers(self) -> None:
        for transport, name in zip(("uds", "http"), self.workers):
            network = "none" if transport == "uds" else f"container:{self.server}"
            command(
                "docker",
                "run",
                "-d",
                "--name",
                name,
                "--network",
                network,
                "--memory",
                "128m",
                "--cpus",
                "0.5",
                *self.mounts(),
                self.args.worker_image,
                "python",
                "/soak/soak.py",
                "--role",
                "worker",
                "--transport",
                transport,
            )

    def produce(self, action: str, state: dict | None = None) -> dict:
        return decoded(
            command(
                "docker",
                "run",
                "--rm",
                "--network",
                f"container:{self.server}",
                "--memory",
                "128m",
                *self.mounts(),
                self.args.worker_image,
                "python",
                "/soak/soak.py",
                "--role",
                "producer",
                "--action",
                action,
                "--state",
                json.dumps(state or {}),
            )
        )

    def rpc(self, expression: str) -> dict:
        return decoded(
            command(
                "docker",
                "exec",
                self.server,
                "bin/tay_standalone",
                "rpc",
                "value = ("
                + expression
                + '); IO.puts("TAY_SOAK_JSON=" <> Jason.encode!(value))',
            )
        )

    def archive_logs(self, name: str) -> None:
        with (self.output / f"{name}.log").open("a") as stream:
            subprocess.run(
                ["docker", "logs", name],
                stdout=stream,
                stderr=stream,
                timeout=30,
                check=False,
            )

    def remove_workers(self) -> None:
        for name in self.workers:
            command("docker", "stop", "--time", "10", name)
            self.archive_logs(name)
            command("docker", "rm", name)

    def maintain(self, batch: dict) -> None:
        probes = self.produce("seed")
        for transport in probes:
            probes[transport]["witness"] = batch[transport]["witness"]
            probes[transport]["schedule_last_at"] = (
                batch[transport]["schedule_last_at"] or 0
            )
        number = self.report["maintenance_cycles"] + 1
        crash = number % 2 == 1
        if crash:
            command("docker", "kill", "--signal", "KILL", self.server)
        else:
            command("docker", "stop", "--time", "30", self.server)
        self.remove_workers()
        self.archive_logs(self.server)
        command("docker", "rm", self.server)
        backup = f"/var/lib/tay/backup-{number}"
        restored = f"/var/lib/tay/restored-{number}"
        options = (
            f'source: "{self.store}", destination: "{backup}", '
            f'catalog: "{backup}.json", durability: :sync, validated_filesystem: true'
        )
        restore = (
            f'source: "{backup}", destination: "{restored}", '
            f'catalog: "{restored}.json", verify_catalog: "{backup}.json", '
            "durability: :sync, validated_filesystem: true"
        )
        expression = (
            "Application.ensure_all_started(:tay); "
            f"{{:ok, b}} = Tay.Storage.ColdCopy.backup([{options}]); "
            f"{{:ok, r}} = Tay.Storage.ColdCopy.restore([{restore}]); "
            'IO.puts("TAY_SOAK_JSON=" <> Jason.encode!(%{backup: b, restore: r}))'
        )
        evidence = decoded(
            command(
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "-v",
                f"{self.data}:/var/lib/tay",
                "-e",
                "ERL_FLAGS=+S 2:2 +A 2",
                "--entrypoint",
                "bin/tay_standalone",
                self.args.image,
                "eval",
                expression,
            )
        )
        self.store = restored
        self.start_engine()
        self.start_workers()
        recovered = self.produce("verify", probes)
        compacted = self.rpc(
            "{:ok, _} = Tay.compact(timeout: 120_000, terminal_retention: {:hours, 0}); %{completed: true}"
        )
        self.report["maintenance_cycles"] = number
        self.event(
            "maintenance",
            number=number,
            crash=crash,
            copies=evidence,
            recovered=recovered,
            compaction=compacted,
        )

    def run(self) -> None:
        started = time.monotonic()
        try:
            repo = Path(__file__).resolve().parent.parent
            snapshot = self.output / "snapshot"
            snapshot.mkdir()
            shutil.copyfile(__file__, snapshot / "soak.py")
            shutil.copytree(
                repo / "clients/python/tay",
                snapshot / "sdk/tay",
                ignore=shutil.ignore_patterns("__pycache__"),
            )
            (snapshot / "source.diff").write_text(
                command("git", "-C", str(repo), "diff", "HEAD", "--binary") + "\n"
            )
            self.report.update(
                {
                    "revision": command("git", "-C", str(repo), "rev-parse", "HEAD"),
                    "dirty": bool(
                        command("git", "-C", str(repo), "status", "--porcelain")
                    ),
                    "image": command(
                        "docker",
                        "image",
                        "inspect",
                        "--format",
                        "{{.Id}}",
                        self.args.image,
                    ),
                    "worker_image": command(
                        "docker",
                        "image",
                        "inspect",
                        "--format",
                        "{{.Id}}",
                        self.args.worker_image,
                    ),
                    "harness_sha256": hashlib.sha256(
                        Path(__file__).read_bytes()
                    ).hexdigest(),
                }
            )
            # Pin immutable IDs so retagging cannot change a running experiment.
            self.args.image = self.report["image"]
            self.args.worker_image = self.report["worker_image"]
            for volume in (self.data, self.socket):
                command("docker", "volume", "create", volume)
            self.start_engine()
            self.report["environment"] = self.rpc(
                "%{engine_version: to_string(Application.spec(:tay, :vsn)), "
                "elixir: System.version(), otp: System.otp_release(), "
                "architecture: to_string(:erlang.system_info(:system_architecture)), "
                'filesystem: String.trim(elem(System.cmd("stat", '
                '["-f", "-c", "%T", System.fetch_env!("TAY_DATA_DIR")]), 0))}'
            )
            self.start_workers()
            self.produce("register")
            self.report["status"] = "running"
            started = time.monotonic()
            self.report["expected_finish_at"] = time.time() + self.args.seconds
            while True:
                batch = self.produce("batch")
                self.report["cycles"] += 1
                self.report["completed_jobs"] += sum(v["jobs"] for v in batch.values())
                if self.report["cycles"] % self.args.maintenance_every == 0:
                    self.maintain(batch)
                status = self.rpc(
                    "%{status: Map.take(Tay.status(), [:state, :active_jobs, :running_executions, "
                    ":unsettled_executions, :state_bytes, :history_bytes]), "
                    "beam_memory_bytes: :erlang.memory(:total)}"
                )
                stats = json.loads(
                    command(
                        "docker",
                        "stats",
                        "--no-stream",
                        "--format",
                        "{{json .}}",
                        self.server,
                    )
                )
                used = (
                    int(
                        command(
                            "docker", "exec", self.server, "du", "-sk", "/var/lib/tay"
                        ).split()[0]
                    )
                    * 1024
                )
                if used > self.args.max_disk_mib * 1024 * 1024:
                    raise RuntimeError("soak disk budget exceeded")
                self.report["elapsed_seconds"] = time.monotonic() - started
                self.event(
                    "sample",
                    cycle=self.report["cycles"],
                    batch=batch,
                    engine=status,
                    container=stats,
                    data_bytes=used,
                )
                self.save()
                if self.report["elapsed_seconds"] >= self.args.seconds:
                    break
                time.sleep(
                    min(
                        self.args.interval,
                        self.args.seconds - self.report["elapsed_seconds"],
                    )
                )
            if self.report["maintenance_cycles"] == 0:
                self.maintain(batch)
            self.report["status"] = "passed"
        except BaseException as exc:
            self.report["status"] = (
                "interrupted" if isinstance(exc, KeyboardInterrupt) else "failed"
            )
            self.report["error"] = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            self.report["elapsed_seconds"] = time.monotonic() - started
            for name in [*self.workers, self.server]:
                subprocess.run(
                    ["docker", "stop", "--time", "10", name],
                    capture_output=True,
                    timeout=45,
                    check=False,
                )
                self.archive_logs(name)
            self.save()


def main() -> None:
    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--role", choices=("controller", "worker", "producer"), default="controller"
    )
    parser.add_argument("--transport", choices=("uds", "http"), default="uds")
    parser.add_argument(
        "--action", choices=("register", "batch", "seed", "verify"), default="batch"
    )
    parser.add_argument("--state", default="{}")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--image", default="tay:soak")
    parser.add_argument("--worker-image", default="tay-worker:rc3")
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--maintenance-every", type=int, default=30)
    parser.add_argument("--max-disk-mib", type=int, default=5120)
    args = parser.parse_args()
    if args.role == "worker":
        asyncio.run(worker(args.transport))
    elif args.role == "producer":
        asyncio.run(producer(args.action, json.loads(args.state)))
    else:
        if args.output is None or not args.output.is_absolute():
            parser.error("--output must be a new absolute directory")
        if not (
            1 <= args.seconds <= 259_200
            and args.interval > 0
            and args.maintenance_every > 0
            and args.max_disk_mib > 0
        ):
            parser.error(
                "duration must be 1..259200 seconds; other limits must be positive"
            )
        Soak(args).run()


if __name__ == "__main__":
    main()
