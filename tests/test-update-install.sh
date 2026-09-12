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

setup_fixture pre_fail
if Q2_UPDATE_ALLOW_TEST_ROOT=1 Q2_UPDATE_FAIL_STAGE=1 "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output" 2>&1; then
  echo "pre-promotion failure injection unexpectedly passed" >&2
  exit 1
fi
grep -q '^old-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
[ -z "$(find "$ROOT" -maxdepth 1 -type d -name 'Quake2.rollback-*' -print)" ]

setup_fixture after_backup_fail
if Q2_UPDATE_ALLOW_TEST_ROOT=1 Q2_UPDATE_FAIL_AFTER_BACKUP=1 "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output" 2>&1; then
  echo "post-backup failure injection unexpectedly passed" >&2
  exit 1
fi
grep -q '^old-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
[ -z "$(find "$ROOT" -maxdepth 1 -type d -name 'Quake2.rollback-*' -print)" ]

setup_fixture post_fail
if Q2_UPDATE_ALLOW_TEST_ROOT=1 Q2_UPDATE_FAIL_POSTPUBLISH=1 "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output" 2>&1; then
  echo "post-promotion failure injection unexpectedly passed" >&2
  exit 1
fi
grep -q '^old-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
[ -n "$(find "$ROOT" -maxdepth 1 -type d -name 'Quake2.failed-update-*' -print)" ]

setup_fixture success
Q2_UPDATE_ALLOW_TEST_ROOT=1 "$HELPER" "$SOURCE" "$DEST" >"$ROOT/output"
grep -q '^new-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
grep -q '^retail-data$' "$DEST/baseq2/pak0.pak"
grep -q '^set sensitivity 7$' "$DEST/baseq2/autoexec.cfg"
ROLLBACK=$(awk -F= '/^ROLLBACK_PATH=/{print $2}' "$ROOT/output")
[ -d "$ROLLBACK" ]
grep -q '^old-engine$' "$ROLLBACK/Quake2.app/Contents/MacOS/quake2"
Q2_UPDATE_ALLOW_TEST_ROOT=1 "$HELPER" --restore "$ROLLBACK" "$DEST" >"$ROOT/restore-output"
grep -q '^old-engine$' "$DEST/Quake2.app/Contents/MacOS/quake2"
SUPERSEDED=$(awk -F= '/^SUPERSEDED_PATH=/{print $2}' "$ROOT/restore-output")
[ -d "$SUPERSEDED" ]
grep -q '^new-engine$' "$SUPERSEDED/Quake2.app/Contents/MacOS/quake2"

echo "update-install fixtures: PASS"
