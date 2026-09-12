#!/usr/bin/env bash
# Validate an exact release DMG, then update an occupied /Applications/Quake2
# through the canonical host claim and the rollback-safe target-side primitive.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = --restore ]; then
  HOST=${2:?usage: update-dmg.sh --restore <machine> <rollback-path>}
  ROLLBACK=${3:?usage: update-dmg.sh --restore <machine> <rollback-path>}
  case "$ROLLBACK" in
    /Applications/Quake2.rollback-*) ;;
    *) echo "refusing non-update rollback path: $ROLLBACK" >&2; exit 2 ;;
  esac
  case "$ROLLBACK" in
    *[!A-Za-z0-9_./-]*) echo "rollback path contains unsafe characters" >&2; exit 2 ;;
  esac
  PICK="$REPO_ROOT/scripts/pick-bench-host.sh"
  if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ]; then
    export RETRO_BENCH_LOCK="$HOST"
    exec "$PICK" --run "$HOST" "restore-dmg" -- "$0" "$@"
  fi
  scp -q "$REPO_ROOT/scripts/update-install-tree.sh" "$HOST:Desktop/q2-update-install-tree.sh"
  ssh "$HOST" bash -s "$ROLLBACK" <<'RESTORE_EOF'
set -e
ROLLBACK=$1
trap 'rm -f "$HOME/Desktop/q2-update-install-tree.sh"' EXIT HUP INT TERM
bash "$HOME/Desktop/q2-update-install-tree.sh" --restore "$ROLLBACK" /Applications/Quake2
rm -f "$HOME/Desktop/q2-update-install-tree.sh"
trap - EXIT HUP INT TERM
RESTORE_EOF
  exit 0
fi

if [ "${1:-}" = --preflight ]; then
  PREFLIGHT_ONLY=1
  VERSION=${2:?usage: update-dmg.sh --preflight <version>}
  HOST=
else
  PREFLIGHT_ONLY=0
  HOST=${1:?usage: update-dmg.sh <machine> <version>}
  VERSION=${2:?usage: update-dmg.sh <machine> <version>}
fi

DMG="$REPO_ROOT/dist/Quake2-OldMac-$VERSION.dmg"
[ -f "$DMG" ] || { echo "missing exact update artifact: $DMG" >&2; exit 1; }
DMG_BASE=$(basename "$DMG")

if [ "$PREFLIGHT_ONLY" = 0 ]; then
  PICK="$REPO_ROOT/scripts/pick-bench-host.sh"
  if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ]; then
    export RETRO_BENCH_LOCK="$HOST"
    exec "$PICK" --run "$HOST" "update-dmg" -- "$0" "$@"
  fi
fi

MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/q2-update-preflight.XXXXXX")
mounted=no
cleanup_preflight() {
  if [ "$mounted" = yes ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup_preflight EXIT HUP INT TERM
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
mounted=yes

for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  [ -f "$MOUNT/$relative" ] || { echo "candidate missing $relative" >&2; exit 1; }
done
[ -f "$MOUNT/Quake2.app/Contents/MacOS/libSDL2-2.0.0.dylib" ] || {
  echo "candidate arm64 runtime is missing Contents/MacOS/libSDL2-2.0.0.dylib" >&2
  exit 1
}
ARCHS=$(lipo -archs "$MOUNT/Quake2.app/Contents/MacOS/quake2")
[ "$ARCHS" = "ppc750 ppc7400 ppc970 x86_64 i386 arm64" ] || {
  echo "candidate slice mismatch: $ARCHS" >&2
  exit 1
}
codesign --verify --deep --strict "$MOUNT/Quake2.app"
DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
DMG_MD5=$(md5 "$DMG" | awk '{print $NF}')
echo "[update-dmg] artifact=$DMG_BASE sha256=$DMG_SHA"
echo "[update-dmg] slices=$ARCHS signature=valid"
for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  echo "[update-dmg] $relative $(md5 "$MOUNT/$relative" | awk '{print $NF}')"
done

hdiutil detach "$MOUNT" >/dev/null
mounted=no
rmdir "$MOUNT"
trap - EXIT HUP INT TERM
[ "$PREFLIGHT_ONLY" = 0 ] || exit 0

ssh "$HOST" '[ -d /Applications/Quake2/Quake2.app ] && [ ! -L /Applications/Quake2 ]' || {
  echo "[update-dmg $HOST] REFUSE: expected occupied install is absent or unsafe" >&2
  exit 10
}

echo "[update-dmg $HOST] copy and verify $DMG_BASE"
ssh "$HOST" 'mkdir -p ~/Desktop'
scp -q "$DMG" "$HOST:Desktop/$DMG_BASE"
scp -q "$REPO_ROOT/scripts/update-install-tree.sh" "$HOST:Desktop/q2-update-install-tree.sh"
# DMG_BASE is basename(1) of our own `Quake2-OldMac-$VERSION.dmg` path and is
# intentionally expanded locally; the remote md5 output is parsed locally.
# shellcheck disable=SC2029
REMOTE_MD5=$(ssh "$HOST" md5 "Desktop/$DMG_BASE" | awk '{print $NF}')
[ "$REMOTE_MD5" = "$DMG_MD5" ] || {
  echo "[update-dmg $HOST] FATAL: remote DMG mismatch $REMOTE_MD5 != $DMG_MD5" >&2
  exit 1
}

ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE=$1
MOUNT="$HOME/q2-update-mnt.$$"
cleanup_remote() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
  rmdir "$MOUNT" 2>/dev/null || true
  rm -f "$HOME/Desktop/q2-update-install-tree.sh"
}
trap cleanup_remote EXIT HUP INT TERM
[ ! -e "$MOUNT" ] || { echo "occupied update mount: $MOUNT" >&2; exit 11; }
mkdir "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$HOME/Desktop/$DMG_BASE" >/dev/null
bash "$HOME/Desktop/q2-update-install-tree.sh" "$MOUNT" /Applications/Quake2
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"
rm -f "$HOME/Desktop/q2-update-install-tree.sh"
trap - EXIT HUP INT TERM
REMOTE_EOF

echo "[update-dmg $HOST] installed and retained named rollback from $DMG_BASE"
