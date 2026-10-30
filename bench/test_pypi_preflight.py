from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


class PyPIPreflightTests(unittest.TestCase):
    def run_gate(self, results: str, active: str = "", gh_exit: int = 0):
        workflow = (
            pathlib.Path(__file__).resolve().parents[1]
            / ".github/workflows/publish-python.yml"
        ).read_text()
        section = workflow.split(
            "      - name: Wait for the existing full qualification run\n", 1
        )[1]
        body = textwrap.dedent(
            section.split("        run: |\n", 1)[1].split("\n  publish:", 1)[0]
        )
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            scripts = {
                "python3": """
import os, pathlib, sys
p = pathlib.Path(os.environ['COUNTER'])
n = int(p.read_text()) if p.exists() else 0
p.write_text(str(n + 1))
results = os.environ['GATE_RESULTS'].split(',')
sys.exit(int(results[min(n, len(results) - 1)]))
""",
                "gh": """
import os, sys
print(os.environ['ACTIVE_RUN'])
sys.exit(int(os.environ['GH_EXIT']))
""",
                "sleep": "",
            }
            for name, source in scripts.items():
                path = root / name
                path.write_text(f"#!{sys.executable}\n" + source)
                path.chmod(0o755)
            env = dict(
                os.environ,
                PATH=str(root) + os.pathsep + os.environ["PATH"],
                COUNTER=str(root / "counter"),
                GATE_RESULTS=results,
                ACTIVE_RUN=active,
                GH_EXIT=str(gh_exit),
                GITHUB_REPOSITORY="owner/repo",
                RELEASE_COMMIT="a" * 40,
            )
            result = subprocess.run(
                ["bash", "-c", body],
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            return result, int((root / "counter").read_text())

    def test_qualified_commit_proceeds_without_waiting(self):
        result, calls = self.run_gate("0", gh_exit=9)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 1)

    def test_active_qualification_is_waited_for(self):
        result, calls = self.run_gate(
            "1,0", active="https://github.com/owner/repo/actions/runs/1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Waiting for release qualification", result.stdout)
        self.assertEqual(calls, 2)

    def test_failed_or_missing_qualification_refuses_publication(self):
        result, calls = self.run_gate("1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, 2)

    def test_api_failure_cannot_authorize_publication(self):
        result, calls = self.run_gate("1", gh_exit=9)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(calls, 1)
