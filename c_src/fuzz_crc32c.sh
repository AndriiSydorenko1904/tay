#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
fuzz_dir=$(mktemp -d "${TMPDIR:-/tmp}/tay-crc32c-fuzz.XXXXXX")
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then rm -rf -- "$fuzz_dir";
  else printf 'Fuzz artifacts retained in %s\n' "$fuzz_dir" >&2; fi
}
trap cleanup EXIT
"${TAY_FUZZ_CC:-clang}" -std=c11 -Wall -Wextra -Werror -g -O1 \
  -DTAY_FUZZ_STANDALONE -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$source_dir/tay_crc32c_fuzz.c" -o "$fuzz_dir/fuzz"
"$fuzz_dir/fuzz" "${TAY_FUZZ_RUNS:-100000}"
