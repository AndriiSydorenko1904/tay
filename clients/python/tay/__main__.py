"""Dedicated HTTP/UDS worker and read-only transport diagnostics."""

from __future__ import annotations

import argparse
import asyncio
import importlib
import json
import os
import signal
import sys
from typing import Any

from .client import Tay
from .doctor import diagnose_http, diagnose_socket
from .errors import TayError
from .http import TayHTTPWorker

Worker = Tay | TayHTTPWorker


def _instance(specification: str) -> Worker:
    module_name, separator, attribute = specification.partition(":")
    module = importlib.import_module(module_name)
    if separator:
        candidate: Any = getattr(module, attribute)
        if not isinstance(candidate, (Tay, TayHTTPWorker)):
            raise TypeError(f"{specification!r} is not a Tay or TayHTTPWorker instance")
        return candidate
    candidates = {
        id(value): value
        for value in vars(module).values()
        if isinstance(value, (Tay, TayHTTPWorker))
    }
    if len(candidates) != 1:
        raise RuntimeError(
            f"{module_name!r} must expose exactly one worker, or use module:attribute"
        )
    return next(iter(candidates.values()))


async def _serve(instance: Worker, *, stopped: asyncio.Event | None = None) -> None:
    if isinstance(instance, Tay) and instance.mode != "worker":
        raise RuntimeError("tay-worker requires Tay(mode='worker') or TayHTTPWorker")
    install_signals = stopped is None
    stopped = asyncio.Event() if stopped is None else stopped
    loop = asyncio.get_running_loop()
    installed = []
    if install_signals:
        for current in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(current, stopped.set)
                installed.append(current)
            except NotImplementedError:  # pragma: no cover - non-POSIX event loops
                pass

    async def run() -> None:
        if stopped.is_set():
            return
        if isinstance(instance, TayHTTPWorker):
            await instance.serve_forever()
        else:
            await instance.start()
            await stopped.wait()

    runner = asyncio.create_task(run(), name="tay-worker")
    stopping = asyncio.create_task(stopped.wait(), name="tay-worker-stop")
    try:
        done, _ = await asyncio.wait(
            [runner, stopping], return_when=asyncio.FIRST_COMPLETED
        )
        if runner in done:
            await runner
    finally:
        stopping.cancel()
        runner.cancel()
        await asyncio.gather(runner, stopping, return_exceptions=True)
        try:
            await instance.close()
        finally:
            for current in installed:
                loop.remove_signal_handler(current)


def main(argv: list[str] | None = None) -> int:
    values = list(sys.argv[1:] if argv is None else argv)
    # Preserve `tay-worker module:instance` and `python -m tay module:instance`.
    if values and values[0] not in {"worker", "doctor", "-h", "--help"}:
        values.insert(0, "worker")
    parser = argparse.ArgumentParser(
        description="Tay workers and transport diagnostics"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    worker = commands.add_parser("worker", help="run a dedicated HTTP or socket worker")
    worker.add_argument("application", help="module or module:worker instance")
    doctor = commands.add_parser(
        "doctor", help="check connectivity without submitting jobs"
    )
    target = doctor.add_mutually_exclusive_group()
    target.add_argument("--socket-path")
    target.add_argument("--http-url")
    doctor.add_argument("--timeout", type=float, default=5.0)
    doctor.add_argument("--json", action="store_true", dest="as_json")
    doctor.add_argument("--tls-ca-file")
    doctor.add_argument("--tls-cert-file")
    doctor.add_argument("--tls-key-file")
    doctor.add_argument("--tls-pkcs12-file")
    arguments = parser.parse_args(values)
    try:
        if arguments.command == "worker":
            asyncio.run(_serve(_instance(arguments.application)))
            return 0
        tls = {
            key: getattr(arguments, key)
            for key in (
                "tls_ca_file",
                "tls_cert_file",
                "tls_key_file",
                "tls_pkcs12_file",
            )
            if getattr(arguments, key) is not None
        }
        if arguments.tls_pkcs12_file and "TAY_TLS_PKCS12_PASSWORD" in os.environ:
            tls["tls_pkcs12_password"] = os.environ["TAY_TLS_PKCS12_PASSWORD"]
        if tls and not arguments.http_url:
            parser.error("TLS options require --http-url")
        report = asyncio.run(
            diagnose_http(arguments.http_url, timeout=arguments.timeout, **tls)
            if arguments.http_url
            else diagnose_socket(arguments.socket_path, timeout=arguments.timeout)
        )
        if arguments.as_json:
            print(json.dumps(report, ensure_ascii=True, sort_keys=True))
        else:
            for key, value in report.items():
                print(f"{key}: {value}")
        return 0 if report["ok"] else 1
    except (
        ImportError,
        AttributeError,
        RuntimeError,
        TypeError,
        TayError,
        OSError,
    ) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
