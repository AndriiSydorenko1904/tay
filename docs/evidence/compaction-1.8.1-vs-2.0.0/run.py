import copy
import datetime
import hashlib
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
CONTAINER = "tay-181-vs-200"
HARNESS = "/comparison-harness.exs"
COHORTS = {
    "baseline": ("/baseline", "/git/worktrees/tay-compare-1.8.1", "1.8.1"),
    "candidate": ("/candidate", "/git/worktrees/tay-compare-2.0.0", "2.0.0"),
}
COMMANDS = json.loads((ROOT / "commands.json").read_text()) if (ROOT / "commands.json").exists() else []


def execute(cohort, arguments, label, mix=True):
    checkout, git_dir, _ = COHORTS[cohort]
    command = ["docker", "exec", "-w", checkout,
               "-e", "GIT_DIR=" + git_dir, "-e", "GIT_WORK_TREE=" + checkout,
               "-e", "MIX_BUILD_PATH=/comparison-build/" + cohort,
               "-e", "MIX_DEPS_PATH=/comparison-deps/" + cohort, CONTAINER]
    if mix:
        command += ["mix", "run", "--no-start", "--no-compile", HARNESS]
    command += arguments
    print(label, flush=True)
    started = time.monotonic()
    with (ROOT / (label + ".log")).open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    COMMANDS.append({"label": label, "command": command,
                     "elapsed_seconds": time.monotonic() - started,
                     "exit_code": result.returncode})
    (ROOT / "commands.json").write_text(json.dumps(COMMANDS, indent=2) + "\n")
    result.check_returncode()


def read_file(path):
    return subprocess.check_output(["docker", "exec", CONTAINER, "cat", path])


def read_report(path):
    report = json.loads(read_file(path))
    assert report["working_tree_dirty"] is False
    assert report["durability"] == "sync"
    assert report["filesystem"] == "btrfs"
    assert report["schedulers"] == 2
    assert report["measurement"]["verification"].endswith("restart passed")
    return report


def seed(path, jobs, label):
    execute("baseline", ["--action", "seed", "--fixture", path,
                         "--profile", "bootstrap", "--jobs", str(jobs),
                         "--mode", "sync", "--validated-filesystem", "--timeout-ms", "900000"], label)


def trial(cohort, fixture, label, delta=0):
    path = "/qualification/" + label
    execute(cohort, ["--action", "run", "--fixture", fixture,
                    "--path", path, "--output", path + ".json",
                    "--mode", "sync", "--validated-filesystem",
                    "--timeout-ms", "900000", "--delta-jobs", str(delta)], label)
    report = read_report(path + ".json")
    assert report["version"] == COHORTS[cohort][2]
    assert report["measurement"]["jobs_after"] == report["fixture"]["jobs"] + delta
    (ROOT / (label + ".json")).write_text(json.dumps(report, indent=2) + "\n")
    return report


def dataset(manifest):
    values = {key: manifest[key] for key in ["jobs", "args_bytes", "counts", "samples"]}
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


for cohort in COHORTS:
    trial(cohort, "/qualification/pilot", "pilot-settled-" + cohort)
source = "/qualification/bootstrap"
manifest = json.loads(read_file(source + "/fixture.json"))
dataset_hash = dataset(manifest)
native = {}
for cohort in COHORTS:
    prep = trial(cohort, source, "prepare-native-settled-" + cohort)
    native[cohort] = "/qualification/native-" + cohort
    execute(cohort, ["mkdir", native[cohort]], "mkdir-native-" + cohort, mix=False)
    execute(cohort, ["mix", "tay.storage.backup",
                     "--source", "/qualification/prepare-native-settled-" + cohort + "/store",
                     "--destination", native[cohort] + "/store",
                     "--catalog", native[cohort] + "/catalog.json",
                     "--durability", "sync", "--validated-filesystem"],
            "backup-native-" + cohort, mix=False)
    value = copy.deepcopy(manifest)
    value.update({"profile": "checkpoint", "checkpoint_version": prep["version"],
                  "checkpoint_revision": prep["revision"],
                  "source_fixture_sha256": prep["fixture_sha256"],
                  "catalog_sha256": hashlib.sha256(read_file(native[cohort] + "/catalog.json")).hexdigest()})
    assert dataset(value) == dataset_hash
    content = json.dumps(value, indent=2).encode() + b"\n"
    subprocess.run(["docker", "exec", "-i", CONTAINER, "tee", native[cohort] + "/fixture.json"],
                   input=content, stdout=subprocess.DEVNULL, check=True)
    (ROOT / ("native-fixture-" + cohort + ".json")).write_bytes(content)

# Four measured fresh-VM trials per version and scenario, in ABBA order.
order = ["baseline", "candidate", "candidate", "baseline"] * 2
for scenario, delta in [("bootstrap", 0), ("checkpoint", 0), ("delta", 1)]:
    results = []
    for index, cohort in enumerate(order):
        subprocess.run(["docker", "exec", CONTAINER, "sync", "-f", "/qualification"], check=True)
        fixture = source if scenario == "bootstrap" else native[cohort]
        report = trial(cohort, fixture, f"{scenario}-{index:02d}-{cohort}", delta)
        assert dataset(report["fixture"] | {"samples": manifest["samples"]}) == dataset_hash
        results.append({"cohort": cohort, "report": report})
    (ROOT / (scenario + "-all.json")).write_text(json.dumps(results, indent=2) + "\n")

all_manifests = {"bootstrap": manifest}
for cohort in COHORTS:
    all_manifests[cohort] = json.loads((ROOT / ("native-fixture-" + cohort + ".json")).read_text())
for key, value in all_manifests.items():
    fixture = source if key == "bootstrap" else native[key]
    assert json.loads(read_file(fixture + "/fixture.json")) == value
    assert hashlib.sha256(read_file(fixture + "/catalog.json")).hexdigest() == value["catalog_sha256"]
print("COMPARISON_COMPLETE", datetime.datetime.now(datetime.timezone.utc).isoformat(), flush=True)
