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
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    threshold: float = 20.0,
    max_relative_mad: float = 10.0,
) -> dict[str, Any]:
    if not math.isfinite(threshold) or threshold < 0:
        raise ValueError("regression threshold must be finite and nonnegative")
    if not math.isfinite(max_relative_mad) or max_relative_mad < 0:
        raise ValueError("variability threshold must be finite and nonnegative")
    for key in [
        "report_schema",
        "benchmark",
        "harness_sha256",
        "workload",
        "environment",
        "comparison_protocol",
        "orchestrator_sha256",
        "trial_order",
    ]:
        if baseline.get(key) != candidate.get(key):
            raise ValueError(f"incompatible reports: {key} differs")
    if baseline.get("report_schema") != 1 or baseline.get("benchmark") not in {
        "tay-release-v1",
        "tay-release-v2",
    }:
        raise ValueError("unsupported benchmark report")
    rows = []
    for name, direction in METRICS.items():
        medians = []
        counts = []
        dispersions = []
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
                dispersions.append(None)
            else:
                median = statistics.median(valid)
                medians.append(median)
                dispersions.append(
                    100
                    * statistics.median(abs(value - median) for value in valid)
                    / median
                )
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
                "baseline_relative_mad_percent": dispersions[0],
                "candidate_relative_mad_percent": dispersions[1],
                "noisy": any(
                    value is not None and value > max_relative_mad
                    for value in dispersions
                ),
            }
        )
    return {
        "comparison_schema": 1,
        "baseline_revision": baseline["revision"],
        "candidate_revision": candidate["revision"],
        "baseline_version": baseline["version"],
        "candidate_version": candidate["version"],
        "max_regression_percent": threshold,
        "max_relative_mad_percent": max_relative_mad,
        "workload": candidate["workload"],
        "environment": candidate["environment"],
        "metrics": rows,
        "regressed": any(row["regressed"] for row in rows),
        "noisy": any(row["noisy"] for row in rows),
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
        "| Metric | Baseline median | Candidate median | Regression | Relative MAD baseline/candidate | Samples |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
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
        variability = (
            f"{number(row['baseline_relative_mad_percent'])}% / "
            f"{number(row['candidate_relative_mad_percent'])}%"
        )
        if row["noisy"]:
            variability += " **too noisy**"
        lines.append(
            f"| {row['metric']} | {number(row['baseline'])} | {number(row['candidate'])} | {change} | {variability} | {row['baseline_samples']}/{row['candidate_samples']} |"
        )
    lines += [
        "",
        "Positive regression means worse; negative means improved.",
        f"Relative MAD is median absolute deviation divided by the median; qualification requires each cohort to stay within {report['max_relative_mad_percent']:g}% for every metric. No trials are discarded.",
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
    parser.add_argument("--max-relative-mad-percent", type=float, default=10.0)
    parser.add_argument("--fail-on-regression", action="store_true")
    args = parser.parse_args()
    try:
        report = compare(
            json.loads(args.baseline.read_text()),
            json.loads(args.candidate.read_text()),
            args.max_regression_percent,
            args.max_relative_mad_percent,
        )
        with args.output.open("x") as target:
            json.dump(report, target, indent=2, allow_nan=False)
            target.write("\n")
        with args.markdown.open("x") as target:
            target.write(markdown(report))
    except (ValueError, KeyError, OSError, TypeError) as exc:
        parser.error(str(exc))
    return int(
        args.fail_on_regression
        and (report["regressed"] or report["noisy"] or not report["complete"])
    )


if __name__ == "__main__":
    raise SystemExit(main())
