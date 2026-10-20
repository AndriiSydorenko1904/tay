#!/usr/bin/env bash

# Tay 1.0 readiness evidence collector. This script does not publish artifacts
# or alter production data. Test storage is left to the test suite unless a
# command documented by this repository requires a command-scoped directory.
set -u
set -o pipefail

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "UNKNOWN: run this script from inside the Tay repository" >&2
  exit 2
}
cd "$repo" || exit 2

# A previous audit version exported these variables in its caller's shell. In
# particular, macOS TMPDIR commonly expands through the /var symlink, which the
# native helper correctly refuses because it opens every component O_NOFOLLOW.
# Ordinary local tests must use their repository defaults, while qualification
# commands that need these variables must scope them to that one command.
INHERITED_TAY_TEST_DATA_ROOT=${TAY_TEST_DATA_ROOT-}
INHERITED_TAY_TEST_SYNC=${TAY_TEST_SYNC-}
unset TAY_TEST_DATA_ROOT TAY_TEST_SYNC

RESULT_FILE="$repo/result.txt"
AUDIT_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tay-1.0-audit.XXXXXX") || exit 2
LOG_DIR="$AUDIT_TMP_ROOT/logs"
ARTIFACT_DIR="$AUDIT_TMP_ROOT/release-artifacts"
PYTHON_REQUIREMENTS="$AUDIT_TMP_ROOT/python-audit-requirements.txt"
mkdir -p "$LOG_DIR" "$ARTIFACT_DIR"

: > "$RESULT_FILE"
exec > >(tee "$RESULT_FILE") 2>&1

CHECK_NUMBERS=()
CHECK_NAMES=()
CHECK_STATUSES=()
CHECK_CODES=()

section() {
  printf '\n============================================================\n%s\n============================================================\n' "$1"
}

record_result() {
  CHECK_NUMBERS+=("$1")
  CHECK_NAMES+=("$2")
  CHECK_STATUSES+=("$3")
  CHECK_CODES+=("$4")
  printf '\nRESULT check=%s status=%s exit_code=%s name=%s\n' "$1" "$3" "$4" "$2"
  if [ -n "${5:-}" ]; then
    printf 'CLASSIFICATION: %s\n' "$5"
  fi
}

run_check() {
  local number=$1 name=$2
  shift 2
  local log="$LOG_DIR/check-${number//[^[:alnum:]._-]/_}.log"
  local rc

  section "$number. $name"
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    record_result "$number" "$name" PASS "$rc" "check completed successfully"
  else
    record_result "$number" "$name" FAIL "$rc" "audit command or Tay test failure; inspect $log"
  fi
}

run_exunit_check() {
  local number=$1 name=$2
  shift 2
  local log="$LOG_DIR/check-${number//[^[:alnum:]._-]/_}.log"
  local rc status classification

  section "$number. $name"
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    status=PASS
    classification="ExUnit completed successfully"
  elif grep -Eq '[0-9]+ tests?, [1-9][0-9]* failures?' "$log"; then
    status=FAIL
    classification="actual Tay test failure reported by ExUnit"
  else
    status=UNKNOWN
    classification="test setup, compilation, local environment, or tooling failure"
  fi
  record_result "$number" "$name" "$status" "$rc" "$classification"
}

run_pytest_check() {
  local number=$1 name=$2
  shift 2
  local log="$LOG_DIR/check-${number//[^[:alnum:]._-]/_}.log"
  local rc status classification

  section "$number. $name"
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  case "$rc" in
    0)
      status=PASS
      classification="pytest completed successfully"
      ;;
    1)
      status=FAIL
      classification="actual Python SDK test failure reported by pytest"
      ;;
    *)
      status=UNKNOWN
      classification="pytest collection, interruption, usage, local environment, or tooling failure"
      ;;
  esac
  record_result "$number" "$name" "$status" "$rc" "$classification"
}

skip_check() {
  section "$1. $2"
  printf 'SKIP: %s\n' "$3"
  record_result "$1" "$2" SKIP "-" "missing/non-existent audit target"
}

unknown_check() {
  section "$1. $2"
  printf 'UNKNOWN: %s\n' "$3"
  record_result "$1" "$2" UNKNOWN "127" "missing local tool or audit infrastructure"
}

require_tools_or_unknown() {
  local number=$1 name=$2
  shift 2
  local missing=() tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    unknown_check "$number" "$name" "missing local tool(s): ${missing[*]}"
    return 1
  fi
  return 0
}

run_mix_test_files() {
  local number=$1 name=$2
  shift 2
  local missing=() file
  for file in "$@"; do
    [ -f "$file" ] || missing+=("$file")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    skip_check "$number" "$name" "missing test file(s): ${missing[*]}"
    return
  fi
  require_tools_or_unknown "$number" "$name" mix || return
  run_exunit_check "$number" "$name" mix test --warnings-as-errors "$@"
}

git_grep_report() {
  local pattern=$1
  shift
  local rc
  git grep -nEi "$pattern" -- "$@"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    printf 'No matches.\n'
    return 0
  fi
  return "$rc"
}

echo "Repository: $repo"
echo "Result:     $RESULT_FILE"
echo "Scratch:    $AUDIT_TMP_ROOT"
echo "Started:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "NOTE: no test-storage environment variable is exported globally."
if [ -n "$INHERITED_TAY_TEST_DATA_ROOT" ] || [ -n "$INHERITED_TAY_TEST_SYNC" ]; then
  echo "NOTE: ignored inherited audit test overrides for ordinary local tests:"
  [ -n "$INHERITED_TAY_TEST_DATA_ROOT" ] && \
    echo "  TAY_TEST_DATA_ROOT=$INHERITED_TAY_TEST_DATA_ROOT"
  [ -n "$INHERITED_TAY_TEST_SYNC" ] && echo "  TAY_TEST_SYNC=$INHERITED_TAY_TEST_SYNC"
fi

check_public_api() {
  git_grep_report '^(defmodule |[[:space:]]*@doc|[[:space:]]*@spec|[[:space:]]*@type|[[:space:]]*@callback|[[:space:]]*def(macro)?[[:space:]])' lib mix.exs || return
  printf '\n=== Public Mix tasks ===\n'
  find lib/mix/tasks -type f -name '*.ex' -print | sort
  printf '\n=== Python package exports ===\n'
  sed -n '1,260p' clients/python/tay/__init__.py
  grep -RInE '^(class |async def |def )' clients/python/tay --include='*.py'
  rc=$?
  [ "$rc" -le 1 ]
}
run_check "1" "Public API surface and exported functions" check_public_api

run_check "2" "Deprecated, TODO, FIXME, and temporary APIs" \
  git_grep_report 'deprecated|deprecation|TODO|FIXME|HACK|XXX|temporary|provisional|remove in|remove after|legacy|obsolete' \
  lib test config docs README.md CHANGELOG.md RELEASING.md clients/python standalone bench .github \
  ':!standalone/deps'

check_storage_compatibility() {
  git_grep_report 'store.?v[0-9]|segment.?v[0-9]|event.?v[0-9]|format.?version|magic|codec|CURRENT|epoch|migration' \
    lib/tay/storage lib/tay/event.ex lib/tay/event test/fixtures docs || return
  printf '\n=== Compatibility fixtures ===\n'
  find test/fixtures -maxdepth 5 -type f -print | sort
  printf '\n=== Fixture manifests and checksums ===\n'
  find test/fixtures -type f \( -name SHA256SUMS -o -name manifest.exs -o -name README.md \) \
    -print -exec sed -n '1,240p' {} \;
}
run_check "3a" "Storage format constants and compatibility inventory" check_storage_compatibility
run_mix_test_files "3b" "Storage codec and frozen-fixture tests" \
  test/tay/event/codec_test.exs \
  test/tay/storage/record_fixture_test.exs \
  test/tay/storage/segment_codec_test.exs \
  test/tay/storage/v2_authority_test.exs

check_recovery_inventory() {
  find test/tay -type f \( -iname '*recovery*' -o -iname '*restart*' -o -iname '*crash*' \) -print | sort
  git_grep_report 'test .*(recover|restart|crash|kill|truncate|torn|corrupt)' test/tay
}
run_check "4a" "Recovery and crash test inventory" check_recovery_inventory
run_mix_test_files "4b" "Recovery and crash executable tests" \
  test/tay/state/recovery_test.exs \
  test/tay/storage/recovery_test.exs \
  test/tay/storage/recovery_adversarial_test.exs \
  test/tay/storage/recovery_lifecycle_test.exs \
  test/tay/storage/recovery_semantics_test.exs \
  test/tay/storage/v2_vm_crash_test.exs \
  test/tay/system/independent_crash_matrix_test.exs \
  test/tay/execution/restart_test.exs

run_check "5a" "Disk-full, I/O, and permission fault coverage inventory" \
  git_grep_report 'ENOSPC|disk.?full|no space|EIO|I/O|EACCES|EPERM|permission|read.?only|write.?fault|sync.?fault|fsync|fdatasync|fault' \
  c_src lib test docs
run_mix_test_files "5b" "Filesystem fault executable tests" \
  test/tay/engine/fault_test.exs \
  test/tay/execution/fault_test.exs \
  test/tay/execution/operations_fault_test.exs \
  test/tay/storage/native_protocol_test.exs \
  test/tay/storage/native_test.exs \
  test/tay/storage/storage_append_test.exs \
  test/tay/storage/storage_ownership_test.exs \
  test/tay/storage/v2_fault_matrix_test.exs \
  test/tay/storage/v2_refusal_test.exs

run_check "6a" "Compaction implementation and configuration inventory" \
  git_grep_report 'compaction|terminal_retention|max_terminal|high.?water|cooldown|sealed' \
  lib/tay config docs standalone/lib standalone/config
run_mix_test_files "6b" "Compaction executable tests" \
  test/tay/engine/compaction_policy_test.exs \
  test/tay/engine/compaction_runtime_test.exs \
  test/tay/engine/compaction_test.exs

run_check "7a" "Retry, scheduling, cancellation, and delivery-semantics inventory" \
  git_grep_report 'retry|backoff|schedule|cron|cancel|at.?least.?once|exactly.?once|idempoten|attempt|reservation|fence' \
  lib docs README.md clients/python/README.md test/tay
run_mix_test_files "7b" "Retry, scheduling, and cancellation executable tests" \
  test/tay/execution/retry_test.exs \
  test/tay/execution/control_test.exs \
  test/tay/execution/lifecycle_test.exs \
  test/tay/execution/outcome_test.exs \
  test/tay/execution/local_fence_test.exs \
  test/tay/schedule_test.exs \
  test/tay/schedule/cron_test.exs

run_check "8a" "Graceful shutdown and inflight handling inventory" \
  git_grep_report 'shutdown|terminate|stop|drain|in.?flight|quiesc|graceful|supervisor|disconnect|reservation' \
  lib test/tay docs standalone
run_mix_test_files "8b" "Graceful shutdown and inflight executable tests" \
  test/tay/application_test.exs \
  test/tay/engine/lifecycle_test.exs \
  test/tay/execution/lifecycle_test.exs \
  test/tay/execution/independent_vm_test.exs \
  test/tay/storage/storage_lifecycle_test.exs \
  test/tay/storage/storage_supervision_test.exs \
  test/tay/worker_test.exs

run_check "9a" "Backpressure, capacity, and overload inventory" \
  git_grep_report 'backpressure|overload|capacity|max_(jobs|state|concurrency|terminal)|admission|slot|queue.?full|busy|refus' \
  lib config docs README.md standalone/lib clients/python
run_mix_test_files "9b" "Backpressure and capacity executable tests" \
  test/tay/engine/admission_test.exs \
  test/tay/engine/admission_race_test.exs \
  test/tay/engine/capacity_test.exs \
  test/tay/engine/operational_capacity_test.exs \
  test/tay/executor/connection_concurrency_test.exs \
  test/tay/executor/dispatch_fairness_test.exs \
  test/tay/execution/resource_test.exs

check_backup_inventory() {
  sed -n '1,260p' lib/mix/tasks/tay.storage.backup.ex || return
  sed -n '1,260p' lib/mix/tasks/tay.storage.restore.ex || return
  git_grep_report 'backup|restore|cold.?copy|catalog|sha-?256|live owner' lib docs test
}
run_check "10a" "Backup, restore, and cold-copy inventory" check_backup_inventory
run_mix_test_files "10b" "Backup, restore, and cold-copy executable tests" \
  test/tay/storage/cold_copy_test.exs \
  test/tay/system/restore_test.exs

run_check "11a" "Health, readiness, telemetry, metrics, and dashboard inventory" \
  git_grep_report 'health|ready|readiness|telemetry|metric|dashboard|diagnostic|status' \
  lib test docs standalone/lib standalone/test standalone/config Dockerfile compose.yml
run_mix_test_files "11b" "Core observability executable tests" \
  test/tay/dashboard/boundary_test.exs \
  test/tay/dashboard/live_test.exs \
  test/tay/execution/readiness_test.exs \
  test/tay/system/diagnostics_test.exs

standalone_observability=(
  standalone/test/tay/standalone/health_test.exs
  standalone/test/tay/dashboard/standalone/config_test.exs
)
missing_standalone=()
for file in "${standalone_observability[@]}"; do
  [ -f "$file" ] || missing_standalone+=("$file")
done
if [ "${#missing_standalone[@]}" -ne 0 ]; then
  skip_check "11c" "Standalone health and dashboard tests" "missing test file(s): ${missing_standalone[*]}"
elif require_tools_or_unknown "11c" "Standalone health and dashboard tests" mix; then
  run_exunit_check "11c" "Standalone health and dashboard tests" bash -c \
    'cd standalone && mix test --warnings-as-errors test/tay/standalone/health_test.exs test/tay/dashboard/standalone/config_test.exs'
fi

run_check "12a" "UDS, TCP, TLS, and security configuration inventory" \
  git_grep_report 'unix|socket|UDS|TCP|HTTP_|TLS|SSL|mTLS|certificate|private key|permission|authentication|authorization|loopback' \
  lib config docs clients/python standalone README.md Dockerfile compose.yml ':!standalone/deps'
run_mix_test_files "12b" "Transport and protocol executable tests" \
  test/tay/executor/server_socket_test.exs \
  test/tay/executor/socket_path_test.exs \
  test/tay/executor/protocol_test.exs \
  test/tay/http/api_test.exs

if [ ! -f standalone/test/tay/standalone/config_test.exs ]; then
  skip_check "12c" "Standalone transport configuration tests" "missing test file: standalone/test/tay/standalone/config_test.exs"
elif require_tools_or_unknown "12c" "Standalone transport configuration tests" mix; then
  run_exunit_check "12c" "Standalone transport configuration tests" bash -c \
    'cd standalone && mix test --warnings-as-errors test/tay/standalone/config_test.exs'
fi

run_check "13a" "Upgrade, migration, and backward-compatibility inventory" \
  git_grep_report 'upgrade|migration|migrat|backward.?compat|forward.?compat|frozen|unsupported version|protocol version|store.?v1|store.?v2' \
  lib test/fixtures test/tay docs CHANGELOG.md RELEASING.md README.md clients/python
run_mix_test_files "13b" "Upgrade and compatibility executable tests" \
  test/tay/event/codec_test.exs \
  test/tay/storage/record_fixture_test.exs \
  test/tay/storage/v2_authority_test.exs \
  test/tay/storage/v2_epoch_test.exs \
  test/tay/storage/v2_v1_migration_test.exs \
  test/tay/executor/protocol_test.exs \
  test/tay/executor/python_interop_test.exs

check_load_inventory() {
  git_grep_report 'load|stress|soak|benchmark|concurr|race|parallel|10000|100000|phase_c|large' \
    test bench .github/workflows docs || return
  printf '\n=== Qualification and benchmark assets ===\n'
  find bench test/tay/qualification -maxdepth 3 -type f -print | sort
  printf '\n=== Profiles advertised by the repository runner ===\n'
  ./bench/run-profile.sh --help
}
if [ -x bench/run-profile.sh ]; then
  run_check "14a" "Load, stress, soak, and concurrency inventory" check_load_inventory
else
  skip_check "14a" "Load, stress, soak, and concurrency inventory" "missing executable benchmark runner: bench/run-profile.sh"
fi

run_benchmark_profile() {
  local profiles profile bench_parent bench_output
  profiles=$(./bench/run-profile.sh --help | awk '/^  [[:alnum:]_-]+[[:space:]]/ {print $1}') || return
  printf 'Detected profiles: %s\n' "$(printf '%s\n' "$profiles" | tr '\n' ' ')"
  if printf '%s\n' "$profiles" | grep -qx smoke; then
    profile=smoke
  else
    profile=$(printf '%s\n' "$profiles" | grep -v '^full$' | sed -n '1p')
  fi
  if [ -z "$profile" ]; then
    printf 'No runnable benchmark profile was detected.\n' >&2
    return 65
  fi
  bench_parent=$(mktemp -d "${TMPDIR:-/tmp}/tay-audit-benchmark.XXXXXX") || return
  bench_output="$bench_parent/$profile"
  printf 'Selected detected profile: %s\nOutput directory: %s\n' "$profile" "$bench_output"
  TAY_BENCH_OUTPUT_DIR="$bench_output" ./bench/run-profile.sh "$profile"
}
if [ ! -x bench/run-profile.sh ]; then
  skip_check "14b" "Detected benchmark profile execution" "missing executable benchmark runner: bench/run-profile.sh"
elif ! require_tools_or_unknown "14b" "Detected benchmark profile execution" mix awk grep sed; then
  :
else
  run_check "14b" "Detected benchmark profile execution" run_benchmark_profile
fi

run_check "15" "Documented guarantees, limitations, and idempotency" \
  git_grep_report 'guarantee|does not guarantee|limitation|unsupported|must not|never|at.?least.?once|exactly.?once|idempoten|durab|acknowledg|best effort|fail.?closed|plaintext|single.?node|power.?loss|filesystem|retention|capacity' \
  README.md CHANGELOG.md RELEASING.md docs clients/python/README.md bench/README.md c_src/README.md standalone/lib

check_release_inventory() {
  sed -n '1,280p' mix.exs || return
  sed -n '1,280p' clients/python/pyproject.toml || return
  sed -n '1,340p' Dockerfile || return
  sed -n '1,300p' RELEASING.md || return
  find .github/workflows -maxdepth 1 -type f -name 'publish-*.yml' -print \
    -exec sed -n '1,360p' {} \;
}
run_check "16a" "Hex, Python, container, and release configuration" check_release_inventory

build_hex_artifact() {
  local output="$ARTIFACT_DIR/tay.tar"
  mix hex.build --output "$output" || return
  printf '\nBuilt Hex artifact:\n'
  ls -lh "$output"
}
if require_tools_or_unknown "16b" "Build Hex artifact without publishing" mix; then
  run_check "16b" "Build Hex artifact without publishing" build_hex_artifact
fi

build_python_artifacts() {
  local dist="$ARTIFACT_DIR/python-dist"
  mkdir -p "$dist"
  uv build clients/python --out-dir "$dist" || return
  printf '\nBuilt Python artifacts:\n'
  find "$dist" -maxdepth 1 -type f -print -exec ls -lh {} \;
  local artifacts=("$dist"/*)
  [ -e "${artifacts[0]}" ] || {
    printf 'No Python artifacts were produced.\n' >&2
    return 66
  }
  uv run --with twine twine check "${artifacts[@]}"
}
if require_tools_or_unknown "16c" "Build and validate Python artifacts without publishing" uv; then
  run_check "16c" "Build and validate Python artifacts without publishing" build_python_artifacts
fi

if [ ! -f test/tay/system/package_test.exs ]; then
  skip_check "16d" "Detached Hex consumer and release test" \
    "missing test file: test/tay/system/package_test.exs"
elif [ ! -f "$ARTIFACT_DIR/tay.tar" ]; then
  skip_check "16d" "Detached Hex consumer and release test" \
    "Hex artifact was not produced by check 16b"
elif require_tools_or_unknown "16d" "Detached Hex consumer and release test" mix; then
  run_exunit_check "16d" "Detached Hex consumer and release test" \
    env TAY_PACKAGE_TEST=1 TAY_PACKAGE_ARCHIVE="$ARTIFACT_DIR/tay.tar" \
    mix test test/tay/system/package_test.exs --warnings-as-errors
fi

test_suite_summary() {
  printf '=== Elixir test files by subsystem ===\n'
  find test -type f -name '*_test.exs' | sort | awk '
  {
    path=$0; sub("^test/", "", path); n=split(path, parts, "/"); subsystem=parts[1]
    if (parts[1] == "tay" && n > 2) subsystem=parts[1] "/" parts[2]
    files[subsystem]++
  }
  END { for (name in files) printf "%-32s files=%d\n", name, files[name] }' | sort
  printf '\n=== Elixir test declarations per file ===\n'
  while IFS= read -r file; do
    count=$(grep -Ec '^[[:space:]]*test[[:space:]]+"' "$file")
    rc=$?
    [ "$rc" -le 1 ] || return "$rc"
    printf '%4d  %s\n' "$count" "$file"
  done < <(find test -type f -name '*_test.exs' | sort)
  printf '\n=== Python tests ===\n'
  grep -RInE '^[[:space:]]*(async )?def test_|^[[:space:]]*class .*Tests' clients/python/tests
  rc=$?
  [ "$rc" -le 1 ]
}
run_check "17a" "Test-suite summary by subsystem" test_suite_summary

if require_tools_or_unknown "17b" "Full normal Elixir suite" mix; then
  run_exunit_check "17b" "Full normal Elixir suite" mix test --warnings-as-errors
fi

if [ ! -f clients/python/pyproject.toml ] || [ ! -d clients/python/tests ]; then
  skip_check "17c" "Normal Python SDK suite" "missing clients/python project or tests"
elif require_tools_or_unknown "17c" "Normal Python SDK suite" uv; then
  run_pytest_check "17c" "Normal Python SDK suite" uv run --with pytest pytest clients/python
fi

dependency_inventory() {
  elixir --version || return
  mix --version || return
  uv --version || return
  printf '\n=== Elixir dependencies ===\n'
  mix deps || return
  printf '\n=== Elixir dependency tree ===\n'
  mix deps.tree || return
  printf '\n=== Locked Elixir versions ===\n'
  sed -n '1,360p' mix.lock || return
  printf '\n=== Python dependency metadata ===\n'
  uv run --project clients/python python - <<'PY'
from pathlib import Path
import tomllib

data = tomllib.loads(Path("clients/python/pyproject.toml").read_text())
project = data["project"]
print("requires-python:", project.get("requires-python"))
print("dependencies:", project.get("dependencies", []))
print("optional-dependencies:", project.get("optional-dependencies", {}))
print("build-system:", data.get("build-system", {}))
PY
}
if require_tools_or_unknown "18a" "Dependency versions and trees" elixir mix uv; then
  run_check "18a" "Dependency versions and trees" dependency_inventory
fi

run_hex_audit() {
  local log="$LOG_DIR/check-18b-security.log" rc status classification
  section "18b. Hex security audit"
  mix hex.audit 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    status=PASS
    classification="Hex audit completed with no reported advisories or retirements"
  elif grep -Eqi 'CVE-[0-9]|GHSA-[[:alnum:]-]+|has been retired|retired packages?:|affected versions?:' "$log"; then
    status=FAIL
    classification="security advisory or retired Hex dependency reported"
  else
    status=UNKNOWN
    classification="Hex audit tooling, registry, network, or environment failure"
  fi
  record_result "18b" "Hex security audit" "$status" "$rc" "$classification"
}
if require_tools_or_unknown "18b" "Hex security audit" mix; then
  run_hex_audit
fi

resolve_python_audit_requirements() {
  uv pip compile clients/python/pyproject.toml \
    --extra http-pkcs12 \
    --output-file "$PYTHON_REQUIREMENTS"
  printf '\nResolved audit input:\n'
  cat "$PYTHON_REQUIREMENTS"
}
if [ ! -f clients/python/pyproject.toml ]; then
  skip_check "18c" "Resolve Python audit dependencies" "missing clients/python/pyproject.toml"
elif require_tools_or_unknown "18c" "Resolve Python audit dependencies" uv; then
  run_check "18c" "Resolve Python audit dependencies" resolve_python_audit_requirements
fi

run_python_security_audit() {
  local log="$LOG_DIR/check-18d-security.log" rc status classification
  section "18d. Python dependency security audit"
  uvx --from pip-audit pip-audit \
    --disable-pip \
    --no-deps \
    --requirement "$PYTHON_REQUIREMENTS" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    status=PASS
    classification="pip-audit completed with no reported vulnerabilities"
  elif grep -Eqi 'Found [1-9][0-9]* known vulnerabilit|^Name[[:space:]]+Version[[:space:]]+ID([[:space:]]|$)' "$log"; then
    status=FAIL
    classification="Python dependency vulnerabilities reported"
  else
    status=UNKNOWN
    classification="pip-audit or uv tooling, registry, network, or environment failure"
  fi
  record_result "18d" "Python dependency security audit" "$status" "$rc" "$classification"
}
if [ ! -f "$PYTHON_REQUIREMENTS" ]; then
  skip_check "18d" "Python dependency security audit" "Python audit requirements were not produced by check 18c"
elif require_tools_or_unknown "18d" "Python dependency security audit" uvx; then
  run_python_security_audit
fi

check_skipped_tests() {
  git_grep_report '@tag.*(skip|exclude)|@moduletag.*(skip|exclude)|skip:|exclude:|System\.get_env|TAY_.*TEST|flaky|disabled|conditional' \
    test .github/workflows mix.exs config || return
  printf '\n=== Explicit test tags ===\n'
  git_grep_report '@(tag|moduletag)' test || return
  printf '\n=== CI test filters ===\n'
  git_grep_report 'mix test.*(--exclude|--only)|exclude:|only:' .github/workflows mix.exs bench
}
run_check "19" "Skipped, excluded, flaky, or conditionally disabled tests" check_skipped_tests

check_incomplete_markers() {
  git_grep_report 'experimental|alpha|beta|incomplete|not implemented|unimplemented|unsupported|temporary|provisional|prototype|future work|follow.?up|phase [a-z0-9]+|phase-[a-z0-9]+|not yet|coming later' \
    lib test config docs README.md CHANGELOG.md RELEASING.md clients/python standalone bench .github ':!standalone/deps' || return
  printf '\n=== Explicit placeholders ===\n'
  git_grep_report 'raise.*(not implemented|unimplemented)|{:error, *:(unimplemented|unsupported|not_implemented)}|TODO|FIXME' \
    lib clients/python standalone/lib test || return
  printf '\n=== Environment and feature gates ===\n'
  git_grep_report 'System\.get_env|Application\.get_env|Application\.fetch_env|TAY_[A-Z0-9_]+' \
    lib config standalone/lib standalone/config clients/python
}
run_check "20" "Experimental, alpha, temporary, or incomplete code" check_incomplete_markers

section "AUDIT SUMMARY"
printf '%-8s %-8s %-10s %s\n' "CHECK" "STATUS" "EXIT" "NAME"
printf '%-8s %-8s %-10s %s\n' "-----" "------" "----" "----"

pass_count=0
fail_count=0
skip_count=0
unknown_count=0
for ((i = 0; i < ${#CHECK_NUMBERS[@]}; i++)); do
  printf '%-8s %-8s %-10s %s\n' \
    "${CHECK_NUMBERS[$i]}" "${CHECK_STATUSES[$i]}" "${CHECK_CODES[$i]}" "${CHECK_NAMES[$i]}"
  case "${CHECK_STATUSES[$i]}" in
    PASS) pass_count=$((pass_count + 1)) ;;
    FAIL) fail_count=$((fail_count + 1)) ;;
    SKIP) skip_count=$((skip_count + 1)) ;;
    UNKNOWN) unknown_count=$((unknown_count + 1)) ;;
  esac
done

printf '\nPASS:    %d\n' "$pass_count"
printf 'FAIL:    %d\n' "$fail_count"
printf 'SKIP:    %d\n' "$skip_count"
printf 'UNKNOWN: %d\n' "$unknown_count"
printf '\nResult saved to: %s\n' "$RESULT_FILE"
printf 'Temporary audit artifacts and per-check logs: %s\n' "$AUDIT_TMP_ROOT"
printf 'Finished: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Preserve all check outcomes in result.txt. Return failure only after every
# check has run, making the harness useful both interactively and in CI.
if [ "$fail_count" -ne 0 ] || [ "$unknown_count" -ne 0 ]; then
  exit 1
fi
exit 0
