"""Measure compiled release checkouts in balanced ABBA order, using fresh VMs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

PROTOCOL = "balanced-abba-v1; fresh VM per trial; syncfs before Linux sync trials"
IDENTITY = (
    "report_schema",
    "benchmark",
    "harness_sha256",
    "workload",
    "environment",
    "revision",
    "version",
    "working_tree_dirty",
)


def trial_order(trials: int) -> list[str]:
    if trials not in range(2, 11, 2):
        raise ValueError("trials must be an even integer in 2..10 per checkout")
    return ["baseline", "candidate", "candidate", "baseline"] * (trials // 2)


def aggregate(
    reports: list[dict[str, Any]], order: list[str], orchestrator: str
) -> dict[str, Any]:
    if len(reports) != len(order) // 2 or not reports:
        raise ValueError("incomplete trial cohort")
    first = reports[0]
    for report in reports:
        if any(report.get(key) != first.get(key) for key in IDENTITY):
            raise ValueError("trial metadata changed within a checkout")
        if (
            report.get("workload", {}).get("trials") != 1
            or len(report.get("measurements", [])) != 1
        ):
            raise ValueError("expected exactly one measured trial per fresh VM")
    return {
        **first,
        "workload": {**first["workload"], "trials": len(reports)},
        "measurements": [report["measurements"][0] for report in reports],
        "comparison_protocol": PROTOCOL,
        "orchestrator_sha256": orchestrator,
        "trial_order": order,
    }


def run(args: argparse.Namespace) -> None:
    order = trial_order(args.trials)
    if args.mode == "sync" and not args.validated_filesystem:
        raise ValueError("sync requires an explicitly validated local filesystem")
    if not 1 <= args.jobs <= 100_000 or not 1 <= args.clients <= 32:
        raise ValueError("jobs/clients are outside benchmark bounds")
    data = args.data_root.resolve()
    output = args.output_dir.resolve()
    if data.exists():
        raise ValueError("data root must be a new disposable path")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.glob("*baseline*.json")) or any(output.glob("*candidate*.json")):
        raise ValueError("output directory already contains comparison reports")
    data.mkdir(parents=True)
    checkouts = {
        "baseline": args.baseline.resolve(),
        "candidate": args.candidate.resolve(),
    }
    reports: dict[str, list[dict[str, Any]]] = {key: [] for key in checkouts}
    for index, cohort in enumerate(order):
        if args.mode == "sync" and sys.platform.startswith("linux"):
            subprocess.run(["sync", "-f", str(data)], check=True)
        env = dict(os.environ)
        for variable, base in [
            ("MIX_BUILD_PATH", args.build_root),
            ("MIX_DEPS_PATH", args.deps_root),
        ]:
            if base is None:
                env.pop(variable, None)
            else:
                env[variable] = str(base.resolve() / cohort)
        target = output / f"trial-{index:02d}-{cohort}.json"
        command = [
            "mix",
            "run",
            "--no-start",
            "--no-compile",
            str(args.harness.resolve()),
            "--mode",
            args.mode,
            "--path",
            str(data / f"{index:02d}-{cohort}"),
            "--output",
            str(target),
            "--jobs",
            str(args.jobs),
            "--clients",
            str(args.clients),
            "--trials",
            "1",
        ]
        if args.validated_filesystem:
            command.append("--validated-filesystem")
        subprocess.run(command, cwd=checkouts[cohort], env=env, check=True)
        reports[cohort].append(json.loads(target.read_text()))
    digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    for cohort, samples in reports.items():
        with (output / f"{cohort}.json").open("x") as handle:
            json.dump(aggregate(samples, order, digest), handle, indent=2)
            handle.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["baseline", "candidate", "harness", "data-root", "output-dir"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--deps-root", type=Path)
    parser.add_argument("--mode", choices=["write", "sync"], default="write")
    parser.add_argument("--validated-filesystem", action="store_true")
    parser.add_argument("--jobs", type=int, default=1000)
    parser.add_argument("--clients", type=int, default=8)
    parser.add_argument("--trials", type=int, default=4)
    try:
        run(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
