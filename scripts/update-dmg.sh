#!/usr/bin/env bash
# Validate an exact release DMG, then update an occupied /Applications/Quake2
# through the canonical host claim and the rollback-safe target-side primitive.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = --restore ]; then
  HOST=${2:?usage: update-dmg.sh --restore <machine> <rollback-path>}
  ROLLBACK=${3:?usage: update-dmg.sh --restore <machine> <rollback-path>}
  case "$ROLLBACK" in
    */oldmac/quake2/rollbacks/Quake2.rollback-*) ;;
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
  # Staged as a $HOME dotfile, never ~/Desktop (user rule).
  scp -q "$REPO_ROOT/scripts/update-install-tree.sh" "$HOST:.q2-update-install-tree.sh"
  ssh "$HOST" bash -s "$ROLLBACK" <<'RESTORE_EOF'
set -e
ROLLBACK=$1
trap 'rm -f "$HOME/.q2-update-install-tree.sh"' EXIT HUP INT TERM
bash "$HOME/.q2-update-install-tree.sh" --restore "$ROLLBACK" /Applications/Quake2
rm -f "$HOME/.q2-update-install-tree.sh"
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
# ~/oldmac/quake2, never ~/Desktop (user rule: deploy DMGs/scratch go under
# ~/oldmac/, /Applications holds only the live install).
ssh "$HOST" 'mkdir -p ~/oldmac/quake2'
scp -q "$DMG" "$HOST:oldmac/quake2/$DMG_BASE"
scp -q "$REPO_ROOT/scripts/update-install-tree.sh" "$HOST:.q2-update-install-tree.sh"
# DMG_BASE is basename(1) of our own `Quake2-OldMac-$VERSION.dmg` path and is
# intentionally expanded locally; the remote md5 output is parsed locally.
# shellcheck disable=SC2029
REMOTE_MD5=$(ssh "$HOST" md5 "oldmac/quake2/$DMG_BASE" | awk '{print $NF}')
[ "$REMOTE_MD5" = "$DMG_MD5" ] || {
  echo "[update-dmg $HOST] FATAL: remote DMG mismatch $REMOTE_MD5 != $DMG_MD5" >&2
  exit 1
}

ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE=$1
DMG_PATH="$HOME/oldmac/quake2/$DMG_BASE"
MOUNT="$HOME/q2-update-mnt.$$"

# Retry then force, same pattern as deploy-dmg.sh's own remote install path
# (deploy-dmg.sh:296-301) — a slow PPC disk needs the flush time before
# hdiutil will let go. old-mac-quake2#77, measured live on g5-panther: even
# `-force` by mountpoint path can fail ("No such file or directory") while
# `hdiutil info` still shows the image genuinely attached; only detaching
# the underlying whole-disk device identifier released it. Last-resort
# fallback resolves that identifier from `hdiutil info` instead of giving up.
detach_mount() {
  m="$1"
  k=1
  while [ "$k" -le 5 ]; do
    hdiutil detach "$m" >/dev/null 2>&1 && return 0
    sleep 2
    k=$((k + 1))
  done
  hdiutil detach -force "$m" >/dev/null 2>&1 && return 0
  dev=$(hdiutil info | awk -v mnt="$m" '$0 ~ mnt { print $1; exit }' | sed 's/s[0-9]*$//')
  [ -n "$dev" ] && hdiutil detach "$dev" -force >/dev/null 2>&1
  return 0
}

cleanup_remote() {
  detach_mount "$MOUNT"
  rmdir "$MOUNT" 2>/dev/null || true
  rm -f "$HOME/.q2-update-install-tree.sh" "$DMG_PATH"
}
trap cleanup_remote EXIT HUP INT TERM
[ ! -e "$MOUNT" ] || { echo "occupied update mount: $MOUNT" >&2; exit 11; }
mkdir "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG_PATH" >/dev/null
bash "$HOME/.q2-update-install-tree.sh" "$MOUNT" /Applications/Quake2
detach_mount "$MOUNT"
rmdir "$MOUNT" 2>/dev/null || true
rm -f "$HOME/.q2-update-install-tree.sh" "$DMG_PATH"
trap - EXIT HUP INT TERM
REMOTE_EOF

echo "[update-dmg $HOST] installed and retained named rollback from $DMG_BASE"
