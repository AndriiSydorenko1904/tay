from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


class PublicationPreflightTests(unittest.TestCase):
    def bodies(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        bodies = []
        for name in ("publish-container.yml", "publish-python.yml"):
            source = (root / ".github/workflows" / name).read_text()
            sections = re.findall(
                r"      - name: Verify CI and standalone for the release commit\n(.*?)(?=\n      - name:|\n  publish:|\Z)",
                source,
                re.DOTALL,
            )
            bodies.extend(
                textwrap.dedent(s.split("        run: |\n", 1)[1]) for s in sections
            )
        self.assertEqual(len(bodies), 3)
        return bodies

    def test_publication_requires_only_successful_ci_and_standalone(self):
        for body in self.bodies():
            self.assertNotIn("qualification.yml", body)
            self.assertIn('.headSha == \\"$release_commit\\"', body)
            for scenario, expected in (
                ("passed", 0),
                ("missing", 1),
                ("standalone_missing", 1),
                ("api_error", 9),
            ):
                with (
                    self.subTest(scenario=scenario),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = pathlib.Path(directory)
                    gh = root / "gh"
                    gh.write_text(
                        f"#!{sys.executable}\n"
                        + """
import os, sys
args = sys.argv[1:]
assert args[args.index("--status") + 1] == "success"
assert args[args.index("--commit") + 1]
workflow = args[args.index("--workflow") + 1]
assert workflow in ("ci.yml", "standalone.yml")
scenario = os.environ["SCENARIO"]
if scenario == "api_error":
    sys.exit(9)
if scenario == "passed" or (scenario == "standalone_missing" and workflow == "ci.yml"):
    print("123")
"""
                    )
                    gh.chmod(0o755)
                    env = dict(
                        os.environ,
                        PATH=str(root) + os.pathsep + os.environ["PATH"],
                        SCENARIO=scenario,
                        GITHUB_REPOSITORY="owner/repo",
                    )
                    result = subprocess.run(
                        ["bash", "-c", body],
                        env=env,
                        capture_output=True,
                        text=True,
                        check=False,
                        timeout=5,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
