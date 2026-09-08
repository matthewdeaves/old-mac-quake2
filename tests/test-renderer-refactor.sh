#!/usr/bin/env bash
# Production CPU algorithms and recorded GL calls; no window or fleet access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/q2-renderer-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
compiler="${CC:-cc}"
case "$(uname -s)" in
  Darwin) linker=(-Wl,-dead_strip) ;;
  *) linker=(-Wl,--gc-sections -lm) ;;
esac
"$compiler" -std=gnu99 "${RENDERER_TEST_OPT:--O2}" -g \
  -Wno-deprecated-declarations -ffunction-sections -fdata-sections \
  -fsanitize=address,undefined "$repo_root/tests/renderer-refactor.c" \
  "${linker[@]}" -o "$test_dir/renderer-refactor"
"$test_dir/renderer-refactor"
