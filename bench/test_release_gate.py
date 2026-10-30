from __future__ import annotations

import importlib.util
import pathlib
import unittest

script = (
    pathlib.Path(__file__).resolve().parents[1]
    / ".github/scripts/check_release_qualification.py"
)
spec = importlib.util.spec_from_file_location("release_gate", script)
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseGateTests(unittest.TestCase):
    sha = "a" * 40

    def fetch(self, conclusion="success", job_conclusion="success", head=None):
        def request(endpoint):
            if "/jobs?" in endpoint:
                return [
                    {
                        "jobs": [
                            {
                                "name": "Release qualification gate",
                                "conclusion": job_conclusion,
                            }
                        ]
                    }
                ]
            return [
                {
                    "workflow_runs": [
                        {
                            "id": 12,
                            "head_sha": head or self.sha,
                            "event": "workflow_dispatch",
                            "conclusion": conclusion,
                            "html_url": "https://github.com/owner/repo/actions/runs/12",
                        }
                    ]
                }
            ]

        return request

    def test_accepts_completed_gate_for_exact_commit(self):
        self.assertEqual(
            gate.qualified_run("owner/repo", self.sha, self.fetch()),
            "https://github.com/owner/repo/actions/runs/12",
        )

    def test_skipped_gate_and_failed_runs_cannot_authorize_publication(self):
        for fetch in [
            self.fetch(job_conclusion="skipped"),
            self.fetch(conclusion="failure"),
            self.fetch(head="b" * 40),
        ]:
            self.assertIsNone(gate.qualified_run("owner/repo", self.sha, fetch))

    def test_checks_all_pages_and_requires_the_actual_gate_job(self):
        calls = []

        def fetch(endpoint):
            calls.append(endpoint)
            if "/jobs?" in endpoint:
                return [
                    {
                        "jobs": [
                            {
                                "name": "Release comparison (ubuntu-24.04)",
                                "conclusion": "success",
                            }
                        ]
                    },
                    {
                        "jobs": [
                            {
                                "name": "Release qualification gate",
                                "conclusion": "success",
                            }
                        ]
                    },
                ]
            return [
                {"workflow_runs": []},
                {
                    "workflow_runs": [
                        {
                            "id": 2,
                            "head_sha": self.sha,
                            "event": "workflow_dispatch",
                            "conclusion": "success",
                        }
                    ]
                },
            ]

        self.assertIsNotNone(gate.qualified_run("owner/repo", self.sha, fetch))
        self.assertIn("head_sha=" + self.sha, calls[0])
        self.assertIn("/runs/2/jobs?", calls[1])

    def test_network_failure_propagates_instead_of_approving(self):
        def unavailable(_endpoint):
            raise ValueError("API unavailable")

        with self.assertRaises(ValueError):
            gate.qualified_run("owner/repo", self.sha, unavailable)
