#!/usr/bin/env bash
# Install the release DMG onto a target Mac *exactly the way an end user would*:
# copy the .dmg to the Desktop, mount it, copy its contents into
# ~/Desktop/quake2/, then unmount. This is deliberately the DMG path (not
# deploy.sh's direct rsync) so the test loop exercises the same artifact and
# the same install steps a human performs — that is where the 2026-05-31
# corrupt-DMG / illegal-instruction bug hid (deploy.sh was clean, the DMG
# wasn't). See MISTAKES.md.
#
# usage: scripts/deploy-dmg.sh <machine> [version]
#   machine: yosemite | mini-g4 | imac-g5 | mini-intel | imac-2019 (ssh alias)
#   version: e.g. v2.2.4  (default: newest dist/Quake2-OldMac-*.dmg)
#
# Preserves the user's game data: baseq2/pak*.pak, players/, video/ are left
# untouched; only the app + loose runtime libs are (re)installed.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="${1:?usage: $0 <machine> [version]}"
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
  DMG=$(ls -t "$REPO_ROOT"/dist/Quake2-OldMac-*.dmg 2>/dev/null | head -1)
  [ -n "$DMG" ] || { echo "no dist/Quake2-OldMac-*.dmg found — run scripts/make-dmg.sh" >&2; exit 1; }
else
  DMG="$REPO_ROOT/dist/Quake2-OldMac-$VERSION.dmg"
  [ -f "$DMG" ] || { echo "missing $DMG" >&2; exit 1; }
fi
DMG_BASE=$(basename "$DMG")

# Panther (yosemite) ships rsync 2.5.x but scp is fine everywhere; use scp.
echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/Desktop/"
ssh "$HOST" 'mkdir -p ~/Desktop'
scp -q "$DMG" "$HOST:Desktop/$DMG_BASE"

# Verify the .dmg arrived intact (md5 the local vs remote copy) — defence in
# depth on top of make-dmg.sh's own end-to-end content check.
LCL_MD5=$(md5sum "$DMG" | cut -d' ' -f1)
RMT_MD5=$(ssh "$HOST" "md5 'Desktop/$DMG_BASE' | awk '{print \$NF}'")
[ "$LCL_MD5" = "$RMT_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: scp corrupted the DMG ($LCL_MD5 != $RMT_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] DMG on Desktop verified intact ($RMT_MD5)"

echo "[deploy-dmg $HOST] mount + install into ~/Desktop/quake2/ (preserving game data)"
ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE="$1"
MNT="$HOME/q2install-mnt"
DEST="$HOME/Desktop/quake2"

# fresh mountpoint — detach any stale attach, then rmdir (NEVER rm -rf a path
# that might still be a mounted read-only volume).
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/Desktop/$DMG_BASE" >/dev/null

mkdir -p "$DEST/baseq2"

# md5 helper (portable Panther→Lion: `md5` on macOS prints "MD5 (f) = HASH").
_md5() { md5 "$1" 2>/dev/null | awk '{print $NF}'; }

# Copy one file from mount→dest and VERIFY the installed bytes match the source,
# retrying on mismatch. The G3 (yosemite) has 25-yr-old disk + non-ECC RAM and
# silently corrupts copies (~700 KB of a 1.9 MB ref_gl.so flipped once — see
# MISTAKES.md). deploy used to verify only the DMG-on-Desktop, never the final
# installed file, so it shipped a corrupt renderer that loaded but misrendered.
copy_verified() {
  src="$1"; dst="$2"
  [ -e "$src" ] || { echo "  MISSING in image: $src" >&2; return 1; }
  want=$(_md5 "$src")
  k=1
  while [ $k -le 4 ]; do
    rm -f "$dst"; cp -p "$src" "$dst"; sync
    got=$(_md5 "$dst")
    if [ "$got" = "$want" ]; then return 0; fi
    echo "  [verify] $(basename "$dst") mismatch (try $k): $got != $want — retrying" >&2
    k=$((k+1)); sleep 1
  done
  echo "  FATAL: $(basename "$dst") still corrupt after retries ($got != $want)" >&2
  return 1
}

# Replace the app wholesale so no stale bundle files survive. ditto keeps the
# bundle bit, perms (+x on the binary) and resource forks. Verify the binary
# inside the installed bundle byte-for-byte (with a ditto retry) since that is
# the executable that actually runs.
APP_BIN="Quake2.app/Contents/MacOS/quake2"
appok=no
for k in 1 2 3 4; do
  rm -rf "$DEST/Quake2.app"; ditto "$MNT/Quake2.app" "$DEST/Quake2.app"; sync
  if [ "$(_md5 "$DEST/$APP_BIN")" = "$(_md5 "$MNT/$APP_BIN")" ]; then appok=yes; break; fi
  echo "  [verify] app binary mismatch (try $k) — re-dittoing" >&2; sleep 1
done
[ "$appok" = yes ] || { echo "  FATAL: app binary still corrupt after retries" >&2; exit 7; }

# Loose runtime libs that live OUTSIDE the bundle (Q2 basedir=. resolves them).
copy_verified "$MNT/ref_gl.so"       "$DEST/ref_gl.so"       || exit 7
copy_verified "$MNT/baseq2/game.so"  "$DEST/baseq2/game.so"  || exit 7
[ -f "$MNT/q2ded" ] && { copy_verified "$MNT/q2ded" "$DEST/q2ded" || exit 7; }
echo "  [verify] installed binaries match the image byte-for-byte ✅"

# detach — retry until the slow-disk flush completes; only THEN rmdir the now-
# empty mountpoint (rmdir can't touch mounted contents, so it's safe).
detached=no
for k in 1 2 3 4 5; do
  if hdiutil detach "$MNT" >/dev/null 2>&1; then detached=yes; break; fi
  sleep 2
done
[ "$detached" = yes ] || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true

# Tidy: drop any OTHER Quake2-OldMac-*.dmg left on the Desktop from previous
# rounds — keep only the one we just installed from. The bench Macs have small
# disks and these images pile up across releases.
for old in "$HOME"/Desktop/Quake2-OldMac-*.dmg; do
  [ -e "$old" ] || continue
  if [ "$(basename "$old")" != "$DMG_BASE" ]; then
    rm -f "$old" && echo "removed old image $(basename "$old")"
  fi
done

echo "installed:"
ls -la "$DEST" | awk '{print "  "$NF}' | grep -vE '^\s+\.$|^\s+\.\.$' | grep -v '^  $' || true
echo "app binary archs:"
file "$DEST/Quake2.app/Contents/MacOS/quake2" 2>/dev/null | sed 's/.*: //' || true
REMOTE_EOF

echo "[deploy-dmg $HOST] done — installed from $DMG_BASE"
