"""Require successful full qualification and regression checks for the release SHA."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from collections.abc import Callable
from typing import Any


def pages(endpoint: str) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", endpoint],
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(result.stdout)
    if not isinstance(value, list) or not all(isinstance(page, dict) for page in value):
        raise ValueError("invalid GitHub Actions response")
    return value


def qualified_run(repository: str, commit: str, fetch: Callable = pages) -> str | None:
    endpoint = f"repos/{repository}/actions/workflows/qualification.yml/runs?head_sha={commit}&status=success&per_page=100"
    for page in fetch(endpoint):
        for run in page.get("workflow_runs", []):
            if (
                run.get("head_sha") != commit
                or run.get("conclusion") != "success"
                or run.get("event") != "workflow_dispatch"
            ):
                continue
            run_id = run.get("id")
            if type(run_id) is not int or run_id <= 0:
                continue
            jobs = fetch(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100")
            if any(
                job.get("name") == "Release qualification gate"
                and job.get("conclusion") == "success"
                for group in jobs
                for job in group.get("jobs", [])
            ):
                return str(
                    run.get(
                        "html_url",
                        f"https://github.com/{repository}/actions/runs/{run_id}",
                    )
                )
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--commit")
    args = parser.parse_args()
    repository = args.repository
    if not repository or not re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository
    ):
        parser.error("--repository must identify the GitHub owner/repository")
    if any(part in {".", ".."} for part in repository.split("/")):
        parser.error("invalid repository")
    commit = (
        args.commit
        or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    )
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
        parser.error("--commit must be a full commit SHA")
    try:
        url = qualified_run(repository, commit)
    except (subprocess.CalledProcessError, ValueError) as exc:
        raise SystemExit(
            f"Unable to verify release qualification: {type(exc).__name__}"
        ) from exc
    if url is None:
        raise SystemExit(
            "Release refused: this SHA needs successful full qualification with fail_on_regression=true"
        )
    print(f"Release qualification verified: {url}")


if __name__ == "__main__":
    main()
