from __future__ import annotations

import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from compare import METRICS, compare, markdown


def report():
    return {
        "report_schema": 1,
        "benchmark": "tay-release-v1",
        "revision": "a",
        "version": "1",
        "harness_sha256": "same-script",
        "workload": {"jobs": 100, "trials": 3, "durability": "write"},
        "environment": {"os": "test", "schedulers": 4},
        "measurements": [{name: value for name in METRICS} for value in [90, 100, 110]],
    }


class ComparisonTests(unittest.TestCase):
    def test_equal_medians_do_not_hide_unstable_trials_or_pass_the_cli_gate(self):
        baseline, candidate = report(), report()
        for sample, value in zip(candidate["measurements"], [40, 100, 160]):
            sample["enqueue_ack_p95_us"] = value
        result = compare(baseline, candidate)
        self.assertFalse(result["regressed"])
        self.assertTrue(result["noisy"])
        self.assertIn("too noisy", markdown(result))
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name, value in [("baseline", baseline), ("candidate", candidate)]:
                (root / f"{name}.json").write_text(json.dumps(value))
            command = [
                sys.executable,
                str(pathlib.Path(__file__).with_name("compare.py")),
                str(root / "baseline.json"),
                str(root / "candidate.json"),
                "--output",
                str(root / "comparison.json"),
                "--markdown",
                str(root / "comparison.md"),
                "--fail-on-regression",
            ]
            completed = subprocess.run(
                command, check=False, capture_output=True, text=True
            )
            self.assertEqual(completed.returncode, 1, completed.stderr)

    def test_uses_medians_and_correct_regression_directions(self):
        baseline, candidate = report(), report()
        candidate["measurements"][1]["completed_jobs_per_second"] = 50
        for trial in candidate["measurements"]:
            trial["compaction_us"] *= 1.5
        result = compare(baseline, candidate)
        rows = {row["metric"]: row for row in result["metrics"]}
        self.assertEqual(rows["completed_jobs_per_second"]["candidate"], 90)
        self.assertAlmostEqual(
            rows["completed_jobs_per_second"]["regression_percent"],
            100 / 90 * 100 - 100,
        )
        self.assertTrue(rows["compaction_us"]["regressed"])
        self.assertAlmostEqual(rows["compaction_us"]["regression_percent"], 50)
        self.assertIn("threshold exceeded", markdown(result))

    def test_refuses_incompatible_and_incomplete_measurements(self):
        for field in [
            "report_schema",
            "benchmark",
            "harness_sha256",
            "workload",
            "environment",
            "comparison_protocol",
            "orchestrator_sha256",
            "trial_order",
        ]:
            other = report()
            other[field] = "changed"
            with self.assertRaises(ValueError):
                compare(report(), other)
        for measurements in [[], report()["measurements"][:2]]:
            other = report()
            other["measurements"] = measurements
            with self.assertRaises(ValueError):
                compare(report(), other)

    def test_missing_or_invalid_metrics_are_not_reported_as_zero_or_improvement(self):
        for invalid in [None, 0, -1, float("nan"), float("inf"), True]:
            other = copy.deepcopy(report())
            other["measurements"][0]["peak_rss_bytes"] = invalid
            row = next(
                row
                for row in compare(report(), other)["metrics"]
                if row["metric"] == "peak_rss_bytes"
            )
            self.assertIsNone(row["candidate"])
            self.assertIsNone(row["regression_percent"])
            self.assertFalse(row["regressed"])
        for threshold in [-1, float("nan"), float("inf")]:
            with self.assertRaises(ValueError):
                compare(report(), report(), threshold)
            with self.assertRaises(ValueError):
                compare(report(), report(), max_relative_mad=threshold)
