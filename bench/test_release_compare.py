from __future__ import annotations

import copy
import unittest

from release_compare import aggregate, trial_order


def sample():
    return {
        "report_schema": 1,
        "benchmark": "tay-release-v1",
        "harness_sha256": "harness",
        "workload": {"jobs": 1000, "trials": 1},
        "environment": {"filesystem": "btrfs"},
        "revision": "a" * 40,
        "version": "1.8.0-rc3",
        "working_tree_dirty": False,
        "measurements": [{"completed_jobs_per_second": 200}],
    }


class BalancedReleaseTests(unittest.TestCase):
    def test_order_balances_both_counts_and_temporal_positions(self):
        for trials in [2, 4, 6, 8, 10]:
            order = trial_order(trials)
            self.assertEqual(order.count("baseline"), trials)
            self.assertEqual(order.count("candidate"), trials)
            self.assertEqual(
                sum(i for i, name in enumerate(order) if name == "baseline"),
                sum(i for i, name in enumerate(order) if name == "candidate"),
            )
        for trials in [0, 1, 3, 11]:
            with self.assertRaises(ValueError):
                trial_order(trials)

    def test_aggregate_retains_all_measurements_and_protocol_identity(self):
        result = aggregate([sample(), sample()], trial_order(2), "runner")
        self.assertEqual(result["workload"]["trials"], 2)
        self.assertEqual(len(result["measurements"]), 2)
        self.assertEqual(result["orchestrator_sha256"], "runner")
        self.assertEqual(result["trial_order"], trial_order(2))

    def test_incomplete_or_mixed_trials_are_refused(self):
        with self.assertRaises(ValueError):
            aggregate([sample()], trial_order(2), "runner")
        for key, value in [
            ("revision", "b" * 40),
            ("environment", {"filesystem": "overlay"}),
            ("harness_sha256", "other"),
            ("working_tree_dirty", True),
        ]:
            changed = copy.deepcopy(sample())
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                aggregate([sample(), changed], trial_order(2), "runner")
        changed = sample()
        changed["measurements"] = []
        with self.assertRaises(ValueError):
            aggregate([changed, changed], trial_order(2), "runner")
