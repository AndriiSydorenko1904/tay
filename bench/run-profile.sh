#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: bench/run-profile.sh PROFILE

Profiles:
  smoke      Fast API, execution, scheduling and admission smoke test
  load       Configurable completed-job throughput and cold-restart test
  schedule   Due-time lag while concurrent clients continuously insert jobs
  recovery   Large completed history followed by a measured cold recovery
  storage    Organic segment rotation plus 1/10/100-segment replay
  full       Run every profile above in one result directory

Optional environment:
  TAY_BENCH_OUTPUT_DIR          New output directory (default: /tmp/...)
  TAY_BENCH_JOBS               Jobs for load (default: 20000)
  TAY_BENCH_RECOVERY_JOBS      Jobs for recovery (default: 50000)
  TAY_BENCH_ARGS_BYTES         Payload bytes (default: 1024)
  TAY_BENCH_CLIENTS            Concurrent callers (default: 32)
  TAY_BENCH_MODE               write or sync (default: write)
  TAY_BENCH_VALIDATED_FILESYSTEM=1  Required assertion for sync mode

Every run creates a disposable store. Nothing is run against an existing store.
EOF
}

profile=${1:-}
case "$profile" in
  smoke|load|schedule|recovery|storage|full) ;;
  -h|--help|'') usage; exit 0 ;;
  *) echo "Unknown profile: $profile" >&2; usage >&2; exit 64 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
stamp=$(date -u '+%Y%m%dT%H%M%SZ')
output_dir=${TAY_BENCH_OUTPUT_DIR:-${TMPDIR:-/tmp}/tay-bench-${profile}-${stamp}-$$}
mode=${TAY_BENCH_MODE:-write}
jobs=${TAY_BENCH_JOBS:-20000}
recovery_jobs=${TAY_BENCH_RECOVERY_JOBS:-50000}
args_bytes=${TAY_BENCH_ARGS_BYTES:-1024}
clients=${TAY_BENCH_CLIENTS:-32}

case "$output_dir" in
  /*) ;;
  *) echo "TAY_BENCH_OUTPUT_DIR must be absolute" >&2; exit 64 ;;
esac

case "$mode" in
  write) validated_flag='' ;;
  sync)
    if [ "${TAY_BENCH_VALIDATED_FILESYSTEM:-0}" != 1 ]; then
      echo "sync mode requires TAY_BENCH_VALIDATED_FILESYSTEM=1" >&2
      exit 64
    fi
    validated_flag='--validated-filesystem'
    ;;
  *) echo "TAY_BENCH_MODE must be write or sync" >&2; exit 64 ;;
esac

if [ -e "$output_dir" ]; then
  echo "Output directory already exists: $output_dir" >&2
  exit 73
fi
mkdir -p "$output_dir"
# Tay's native store deliberately rejects symlink path components. macOS /tmp
# is normally a symlink to /private/tmp, so resolve the newly-created parent
# before deriving any store paths.
output_dir=$(CDPATH= cd -- "$output_dir" && pwd -P)

run_case() {
  name=$1
  scenario=$2
  shift 2
  store="$output_dir/store-$name"
  report="$output_dir/$name.json"
  command_file="$output_dir/$name.command.txt"

  printf '%s\n' "mix run --no-start bench/run.exs --scenario $scenario --mode $mode --path $store --output $report $*" > "$command_file"
  echo "==> $name"
  # Intentional word splitting: validated_flag is either empty or one fixed flag.
  # shellcheck disable=SC2086
  (cd "$repo_dir" && mix run --no-start bench/run.exs \
    --scenario "$scenario" --mode "$mode" $validated_flag \
    --path "$store" --output "$report" "$@")
  echo "    report: $report"
}

run_smoke() {
  run_case smoke-lifecycle lifecycle --jobs 200 --args-bytes 256 --clients 8
  run_case smoke-schedule schedule --jobs 8 --args-bytes 256 --clients 8
  run_case smoke-reserve reserve
}

run_load() {
  run_case load lifecycle --jobs "$jobs" --args-bytes "$args_bytes" --clients "$clients"
}

run_schedule() {
  run_case schedule-under-load schedule --jobs 20 --args-bytes "$args_bytes" --clients "$clients"
}

run_recovery() {
  run_case recovery-history lifecycle --jobs "$recovery_jobs" --args-bytes "$args_bytes" --clients "$clients"
}

run_storage() {
  run_case organic-rotation rotation --rotation-segments 2
  run_case replay-topology replay --replay-segments 1,10,100 --args-bytes "$args_bytes"
}

case "$profile" in
  smoke) run_smoke ;;
  load) run_load ;;
  schedule) run_schedule ;;
  recovery) run_recovery ;;
  storage) run_storage ;;
  full)
    run_smoke
    run_load
    run_schedule
    run_recovery
    run_storage
    ;;
esac

echo
echo "Completed. Reports and exact commands: $output_dir"
echo "Stores are preserved for inspection; remove the output directory manually when finished."
