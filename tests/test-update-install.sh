#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/update-install-tree.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/q2-update-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

setup_fixture() {
  CASE=$1
  ROOT="$TMP/$CASE"
  SOURCE="$ROOT/source"
  DEST="$ROOT/Quake2"
  # Scope the swap and the legacy rollbacks dir into this case's throwaway
  # tree, never the real $HOME/oldmac. Same filesystem as DEST, so the swap is
  # still a rename.
  export Q2_UPDATE_SWAP_ROOT="$ROOT/swap"
  export Q2_UPDATE_LEGACY_ROOT="$ROOT/rollbacks"
  mkdir -p "$SOURCE/Quake2.app/Contents/MacOS" "$SOURCE/baseq2"
  mkdir -p "$DEST/Quake2.app/Contents/MacOS" "$DEST/baseq2/players/male"
  printf 'new-engine\n' > "$SOURCE/Quake2.app/Contents/MacOS/quake2"
  printf 'new-renderer\n' > "$SOURCE/ref_gl.so"
  printf 'new-game\n' > "$SOURCE/baseq2/game.so"
  printf 'new-server\n' > "$SOURCE/q2ded"
  printf 'old-engine\n' > "$DEST/Quake2.app/Contents/MacOS/quake2"
  printf 'old-renderer\n' > "$DEST/ref_gl.so"
  printf 'old-game\n' > "$DEST/baseq2/game.so"
  printf 'old-server\n' > "$DEST/q2ded"
  printf 'retail-data\n' > "$DEST/baseq2/pak0.pak"
  printf 'user-model\n' > "$DEST/baseq2/players/male/tris.md2"
  printf 'set sensitivity 7\n' > "$DEST/baseq2/autoexec.cfg"
}

# Fix forward: after any outcome, no copy of an install is left behind.
no_copies_left() {
  [ -z "$(find "$Q2_UPDATE_SWAP_ROOT" "$Q2_UPDATE_LEGACY_ROOT" -mindepth 1 -maxdepth 1 -name 'Quake2.*' -print 2>/dev/null)" ]
}

for injected in Q2_UPDATE_FAIL_STAGE Q2_UPDATE_FAIL_AFTER_BACKUP Q2_UPDATE_FAIL_POSTPUBLISH; do
  setup_fixture "$injected"
  if env Q2_UPDATE_ALLOW_TEST_ROOT=1 "$injected=1" "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output" 2>&1; then
    echo "$injected: failure injection unexpectedly passed" >&2
    exit 1
  fi
  grep -q '^old-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
  grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
  no_copies_left || { echo "$injected: a copy was left behind" >&2; exit 1; }
done

setup_fixture success
# Copies kept by earlier versions of the helper are removed; unrelated files
# next to them are not.
mkdir -p "$Q2_UPDATE_LEGACY_ROOT/Quake2.rollback-20200101T000000Z-aaaaaaaaaaaa" \
  "$Q2_UPDATE_LEGACY_ROOT/Quake2.failed-update-20200101T000000Z-bbbbbbbbbbbb" \
  "$Q2_UPDATE_SWAP_ROOT/Quake2.previous-20200101T000000Z-cccccccccccc"
printf 'keep\n' > "$Q2_UPDATE_SWAP_ROOT/marker"
Q2_UPDATE_ALLOW_TEST_ROOT=1 "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output"
grep -q '^new-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
grep -q '^user-model$' "$DEST/baseq2/players/male/tris.md2"
grep -q '^set sensitivity 7$' "$DEST/baseq2/autoexec.cfg"
no_copies_left || { echo "success: a copy was left behind" >&2; exit 1; }
grep -q '^keep$' "$Q2_UPDATE_SWAP_ROOT/marker"
if grep -q '^ROLLBACK_PATH=' "$ROOT/output"; then echo "ROLLBACK_PATH still printed" >&2; exit 1; fi
! Q2_UPDATE_ALLOW_TEST_ROOT=1 "$HELPER" --restore "$ROOT/x" "$DEST" >/dev/null 2>&1 || {
  echo "--restore should no longer exist" >&2; exit 1; }

echo "update-install fixtures: PASS"
