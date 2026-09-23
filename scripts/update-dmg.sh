#!/usr/bin/env bash
# Validate an exact release DMG, then update an occupied /Applications/Quake2
# through the canonical host claim and the verified-swap target-side primitive.
# Fix forward: no rollback copy is kept; a bad release is replaced by a fixed one.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
# Mount a private clone, not the shared dist/ file. Concurrent attaches of ONE
# image file race in hdiutil ("Resource busy", 1 in 12 with four parallel
# preflights), which silently skipped a g5-tiger update (#85). An APFS clone
# costs nothing; other filesystems get a plain copy.
PRIVATE_DMG="$MOUNT.dmg"
mounted=no
cleanup_preflight() {
  if [ "$mounted" = yes ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT" 2>/dev/null || true
  rm -f "$PRIVATE_DMG"
}
trap cleanup_preflight EXIT HUP INT TERM
cp -c "$DMG" "$PRIVATE_DMG" 2>/dev/null || cp "$DMG" "$PRIVATE_DMG"
cmp -s "$DMG" "$PRIVATE_DMG" || { echo "private DMG copy differs from $DMG" >&2; exit 1; }
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$PRIVATE_DMG" >/dev/null
mounted=yes

for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  [ -f "$MOUNT/$relative" ] || { echo "candidate missing $relative" >&2; exit 1; }
done
[ -f "$MOUNT/Quake2.app/Contents/MacOS/libSDL2-2.0.0.dylib" ] || {
  echo "candidate arm64 runtime is missing Contents/MacOS/libSDL2-2.0.0.dylib" >&2
  exit 1
}
# shellcheck source=scripts/macho-archs.sh
. "$REPO_ROOT/scripts/macho-archs.sh"
ARCHS=$(macho_archs "$MOUNT/Quake2.app/Contents/MacOS/quake2")
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

[ "$PREFLIGHT_ONLY" = 0 ] || exit 0

# The workstation is the canonical picker's LOCAL target: no ssh, no staged
# copy. Install straight from the verified mount. It is also the one Mac where
# a person edits the bundled autoexec-controls.cfg by hand (sound on), so
# lines there that the candidate does not ship are carried over and listed.
# That would also carry a line a release deliberately dropped, which is why
# this is limited to the workstation. (#85)
if [ "$HOST" = workstation ]; then
  [ -d /Applications/Quake2/Quake2.app ] && [ ! -L /Applications/Quake2 ] || {
    echo "[update-dmg workstation] REFUSE: expected occupied install is absent or unsafe" >&2
    exit 10
  }
  CONTROLS=Quake2.app/Contents/Resources/autoexec-controls.cfg
  LOCAL_LINES="$MOUNT.controls"
  grep -vxF -f "$MOUNT/$CONTROLS" "/Applications/Quake2/$CONTROLS" > "$LOCAL_LINES" 2>/dev/null || true
  bash "$REPO_ROOT/scripts/update-install-tree.sh" "$MOUNT" /Applications/Quake2
  if [ -s "$LOCAL_LINES" ]; then
    echo "[update-dmg workstation] kept local lines in $CONTROLS:"
    sed 's/^/    /' "$LOCAL_LINES"
    cat "$LOCAL_LINES" >> "/Applications/Quake2/$CONTROLS"
  fi
  rm -f "$LOCAL_LINES"
  echo "[update-dmg workstation] installed from $DMG_BASE (no rollback kept)"
  exit 0
fi

hdiutil detach "$MOUNT" >/dev/null
mounted=no
rmdir "$MOUNT"
rm -f "$PRIVATE_DMG"
trap - EXIT HUP INT TERM

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
# Under ~/oldmac/quake2/mnt, which the build mirror protects (build.sh).
MOUNT="$HOME/oldmac/quake2/mnt/update.$$"
mkdir -p "$HOME/oldmac/quake2/mnt"

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

echo "[update-dmg $HOST] installed from $DMG_BASE (no rollback kept)"
