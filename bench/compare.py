"""Compare release benchmark reports produced on the same runner/configuration."""

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path
from typing import Any

METRICS = {
    "completed_jobs_per_second": "higher",
    "enqueue_ack_p95_us": "lower",
    "callback_latency_p95_us": "lower",
    "compaction_us": "lower",
    "peak_rss_bytes": "lower",
    "peak_beam_bytes": "lower",
}


def compare(
    baseline: dict[str, Any], candidate: dict[str, Any], threshold: float = 20.0
) -> dict[str, Any]:
    if not math.isfinite(threshold) or threshold < 0:
        raise ValueError("regression threshold must be finite and nonnegative")
    for key in [
        "report_schema",
        "benchmark",
        "harness_sha256",
        "workload",
        "environment",
    ]:
        if baseline.get(key) != candidate.get(key):
            raise ValueError(f"incompatible reports: {key} differs")
    if (
        baseline.get("report_schema") != 1
        or baseline.get("benchmark") != "tay-release-v1"
    ):
        raise ValueError("unsupported benchmark report")
    rows = []
    for name, direction in METRICS.items():
        medians = []
        counts = []
        for report in [baseline, candidate]:
            samples = report.get("measurements", [])
            if len(samples) != report["workload"]["trials"] or not samples:
                raise ValueError("missing benchmark trials")
            values = [sample.get(name) for sample in samples]
            # A missing metric remains missing; do not compare a partial cohort.
            valid = [
                value
                for value in values
                if type(value) in (int, float) and math.isfinite(value) and value > 0
            ]
            if len(valid) != len(values):
                medians.append(None)
            else:
                medians.append(statistics.median(valid))
            counts.append(len(valid))
        before, after = medians
        regression = (
            None
            if before is None or after is None
            else (
                (before / after - 1) * 100
                if direction == "higher"
                else (after / before - 1) * 100
            )
        )
        rows.append(
            {
                "metric": name,
                "baseline": before,
                "candidate": after,
                "baseline_samples": counts[0],
                "candidate_samples": counts[1],
                "direction": direction,
                "regression_percent": regression,
                "regressed": regression is not None and regression > threshold,
            }
        )
    return {
        "comparison_schema": 1,
        "baseline_revision": baseline["revision"],
        "candidate_revision": candidate["revision"],
        "baseline_version": baseline["version"],
        "candidate_version": candidate["version"],
        "max_regression_percent": threshold,
        "workload": candidate["workload"],
        "environment": candidate["environment"],
        "metrics": rows,
        "regressed": any(row["regressed"] for row in rows),
        "complete": all(
            row["baseline"] is not None and row["candidate"] is not None for row in rows
        ),
        "notes": "Median of trial measurements on the same configuration. Sampling and hosted-runner noise remain; this is not production capacity certification.",
    }


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Tay release performance",
        "",
        f"Baseline `{report['baseline_revision']}` → candidate `{report['candidate_revision']}`",
        "",
        "| Metric | Baseline median | Candidate median | Regression | Samples |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for row in report["metrics"]:

        def number(value: float | None) -> str:
            return "missing" if value is None else f"{value:,.2f}"

        change = (
            "missing"
            if row["regression_percent"] is None
            else f"{row['regression_percent']:+.2f}%"
        )
        if row["regressed"]:
            change += " **threshold exceeded**"
        lines.append(
            f"| {row['metric']} | {number(row['baseline'])} | {number(row['candidate'])} | {change} | {row['baseline_samples']}/{row['candidate_samples']} |"
        )
    lines += [
        "",
        "Positive regression means worse; negative means improved.",
        "",
        report["notes"],
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    parser.add_argument("--max-regression-percent", type=float, default=20.0)
    parser.add_argument("--fail-on-regression", action="store_true")
    args = parser.parse_args()
    try:
        report = compare(
            json.loads(args.baseline.read_text()),
            json.loads(args.candidate.read_text()),
            args.max_regression_percent,
        )
        with args.output.open("x") as target:
            json.dump(report, target, indent=2, allow_nan=False)
            target.write("\n")
        with args.markdown.open("x") as target:
            target.write(markdown(report))
    except (ValueError, KeyError, OSError, TypeError) as exc:
        parser.error(str(exc))
    return int(
        args.fail_on_regression and (report["regressed"] or not report["complete"])
    )


if __name__ == "__main__":
    raise SystemExit(main())
