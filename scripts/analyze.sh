#!/usr/bin/env bash
# Lightweight static analysis pass over the renderer + engine source.
# Runs cppcheck (warning class) + clang -fsyntax-only with the warning
# floor we would *like* the Makefile to enforce.
#
# usage:
#   scripts/analyze.sh           # full pass
#   scripts/analyze.sh refresh   # only src/refresh
#   scripts/analyze.sh clang     # skip cppcheck, just clang
#   scripts/analyze.sh cppcheck  # skip clang, just cppcheck
#
# Output goes to stdout. Exit status is always 0 — this is a developer
# tool, not a CI gate. Wire into CI separately if/when that exists.
#
# Filters: stb_image.h (vendored, upstream's problem), the missing
# system include hint, the cppcheck staticFunction style noise (250+
# hygiene hits — file-local funcs missing `static` — not interesting).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/yquake2"

MODE="${1:-all}"
case "$MODE" in
  all)      SUBDIRS="src/refresh src/client src/common" ;;
  refresh)  SUBDIRS="src/refresh" ;;
  clang)    SUBDIRS="src/refresh src/client src/common"; SKIP_CPPCHECK=1 ;;
  cppcheck) SUBDIRS="src/refresh src/client src/common"; SKIP_CLANG=1 ;;
  src/*)    SUBDIRS="$MODE" ;;
  *)        echo "usage: $0 [all|refresh|clang|cppcheck|<src/...>]" >&2; exit 2 ;;
esac

if [ -z "${SKIP_CPPCHECK:-}" ]; then
  if command -v cppcheck >/dev/null; then
    echo "=== cppcheck ($SUBDIRS) ==="
    cppcheck --enable=warning,performance,portability --quiet \
      --suppress=missingIncludeSystem \
      --suppress="*:src/refresh/files/stb_image.h" \
      --error-exitcode=0 \
      $SUBDIRS 2>&1 | grep -Ev '^$' || true
    echo
  else
    echo "[analyze] cppcheck not installed; skipping" >&2
  fi
fi

if [ -z "${SKIP_CLANG:-}" ]; then
  if command -v clang >/dev/null; then
    echo "=== clang -fsyntax-only -Wextra -Wshadow -Wundef -Wpointer-arith ($SUBDIRS) ==="
    # -Iorder mimics the Makefile's include paths just enough that
    # most headers resolve. We don't need a perfect compile — syntax-
    # only is fine for warning extraction.
    # We deliberately do NOT enable -Wmissing-prototypes /
    # -Wstrict-prototypes here — they fire 50+ times on file-local
    # functions that should be `static` (a real hygiene issue, but
    # not the actionable signal we want from `analyze.sh`). They're
    # a separate cleanup. Re-enable them via `scripts/analyze.sh
    # strict` if/when that work happens.
    find $SUBDIRS -name '*.c' -print0 | while IFS= read -r -d '' f; do
      clang -fsyntax-only \
        -Wall -Wextra -Wshadow -Wundef -Wpointer-arith \
        -Wno-unused-parameter \
        -Isrc -Isrc/client/refresh \
        "$f" 2>&1 | grep -E 'warning|error' || true
    done | sort -u
    echo
  else
    echo "[analyze] clang not installed; skipping" >&2
  fi
fi

echo "[analyze] done."
