"""The small, dependency-free dedicated-worker entry point."""

from __future__ import annotations

import argparse
import asyncio
import importlib
import signal
import sys
from typing import Any

from .client import Tay


def _instance(specification: str) -> Tay:
    module_name, separator, attribute = specification.partition(":")
    module = importlib.import_module(module_name)
    if separator:
        candidate: Any = getattr(module, attribute)
        if not isinstance(candidate, Tay):
            raise TypeError(f"{specification!r} is not a Tay instance")
        return candidate

    candidates = tuple(instance for instance in Tay.instances() if instance.__module__ == "tay.client")
    if len(candidates) != 1:
        raise RuntimeError(
            f"{module_name!r} must create exactly one Tay instance, or use module:attribute"
        )
    return candidates[0]


async def _serve(instance: Tay) -> None:
    if instance.mode != "worker":
        raise RuntimeError("tay-worker requires Tay(mode='worker')")

    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for current in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(current, stopped.set)
        except NotImplementedError:  # pragma: no cover - Windows has no UDS support here
            pass

    await instance.start()
    try:
        await stopped.wait()
    finally:
        await instance.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="run a dedicated Tay Python worker")
    parser.add_argument("application", help="module or module:Tay_instance to import")
    arguments = parser.parse_args(argv)
    try:
        asyncio.run(_serve(_instance(arguments.application)))
    except (ImportError, AttributeError, RuntimeError, TypeError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())

