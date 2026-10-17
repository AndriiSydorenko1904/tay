#!/bin/sh
set -eu

case "$(uname -s)" in
  Linux) ;;
  *) echo "release smoke requires Linux durability semantics; skipping"; exit 0 ;;
esac

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
release_source="$repo_dir/standalone/_build/prod/rel/tay_standalone"
test -x "$release_source/bin/tay_standalone"

# Strict durability intentionally rejects the host's /tmp filesystem. Keep the
# smoke Store on the checked-out workspace filesystem instead.
mkdir -p "$repo_dir/tmp"
test_root=$(mktemp -d "$repo_dir/tmp/standalone-smoke.XXXXXX")
release_dir="$test_root/release"
data_dir="$test_root/data/store"
socket_dir="$test_root/socket"
socket_path="$socket_dir/tay.sock"
store_marker="$data_dir/STORE-V2"
current_pointer="$data_dir/CURRENT"
mkdir "$socket_dir"
cp -R "$release_source" "$release_dir"

require_regular_file() {
  if [ ! -f "$1" ]; then
    echo "expected regular file is missing: $1" >&2
    exit 1
  fi
}

checksum() {
  sha256sum "$1" | cut -d ' ' -f 1
}

cleanup() {
  TAY_DATA_DIR="$data_dir" TAY_SOCKET_PATH="$socket_path" \
    "$release_dir/bin/tay_standalone" stop >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

export HOME="$test_root/home"
export RELEASE_TMP="$test_root/tmp"
export ERL_CRASH_DUMP="$test_root/erl_crash.dump"
export TAY_DATA_DIR="$data_dir"
export TAY_SOCKET_PATH="$socket_path"
export TAY_INITIALIZE_IF_MISSING=true
mkdir "$HOME" "$RELEASE_TMP"

"$release_dir/bin/tay_standalone" daemon

attempt=0
until "$release_dir/bin/tay_standalone" rpc 'Tay.Standalone.Health.check!()' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 50
  sleep 0.2
done

test -S "$socket_path"
require_regular_file "$store_marker"
require_regular_file "$current_pointer"
store_before=$(checksum "$store_marker")
current_before=$(checksum "$current_pointer")
"$release_dir/bin/tay_standalone" stop

export TAY_INITIALIZE_IF_MISSING=false
"$release_dir/bin/tay_standalone" daemon
attempt=0
until "$release_dir/bin/tay_standalone" rpc 'Tay.Standalone.Health.check!()' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 50
  sleep 0.2
done
require_regular_file "$store_marker"
require_regular_file "$current_pointer"
store_after=$(checksum "$store_marker")
current_after=$(checksum "$current_pointer")
test "$store_before" = "$store_after" || {
  echo "Store-v2 identity changed across restart" >&2
  exit 1
}
test "$current_before" = "$current_after" || {
  echo "Store-v2 CURRENT pointer changed across restart" >&2
  exit 1
}
"$release_dir/bin/tay_standalone" stop

test ! -e "$release_dir/mix.exs"
test -z "$(find "$release_dir" -type f -name '*.ex' -print -quit)"

export TAY_INITIALIZE_IF_MISSING=maybe
if "$release_dir/bin/tay_standalone" start >/dev/null 2>&1; then
  echo "malformed configuration unexpectedly started" >&2
  exit 1
fi

missing_dir="$test_root/missing-without-initialize"
export TAY_DATA_DIR="$missing_dir"
export TAY_INITIALIZE_IF_MISSING=false
if "$release_dir/bin/tay_standalone" start >/dev/null 2>&1; then
  echo "missing storage unexpectedly started without initialization" >&2
  exit 1
fi
test ! -e "$missing_dir"
