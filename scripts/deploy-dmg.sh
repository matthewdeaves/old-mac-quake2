#!/usr/bin/env bash
# Install the release DMG onto a target Mac *exactly the way an end user would*:
# copy the .dmg to the Desktop, mount it, copy its contents into
# ~/quake2-play/, then unmount. This is deliberately the DMG path (not
# deploy.sh's direct rsync) so the test loop exercises the same artifact and
# the same install steps a human performs — that is where the 2026-05-31
# corrupt-DMG / illegal-instruction bug hid (deploy.sh was clean, the DMG
# wasn't). See MISTAKES.md.
#
# usage: scripts/deploy-dmg.sh <machine> [version]
#   machine: yosemite | yosemite-tiger | sawtooth | quicksilver | mini-g4 |
#            imac-g5 | mini-intel | imac-2019 (ssh alias). yosemite-tiger is
#            the same Mac as yosemite on its 10.4 partition.
#   version: e.g. v2.2.4  (default: newest dist/Quake2-OldMac-*.dmg)
#
# Preserves the user's game data: baseq2/pak*.pak, players/, video/ are left
# untouched; only the app + loose runtime libs are (re)installed.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="${1:?usage: $0 <machine> [version]}"

# Claim this machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK names the machine claimed further up the chain, which is what
# stops the re-exec below recursing. Compare it against the target rather than
# testing whether it is set: a step that targets a DIFFERENT machine still has
# to claim that one, and the emptiness test skipped it silently. Issue #19.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "deploy-dmg" -- "$0" "$@"
fi
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
scp -q "$REPO_ROOT/scripts/clear-launch-quarantine.sh" "$HOST:Desktop/clear-launch-quarantine.sh"

# Fallback for a target whose own hdiutil can't attach ANY disk image
# (old-mac-build-host#41, quad-tiger: exhaustively diagnosed there as a
# userland DiskImages/DiskArbitration fault, survives reboot and a cold
# power-cycle, not fixable from this script). Mount the DMG HERE instead
# and rsync the extracted contents across, skipping hdiutil on the target
# entirely. Mechanism proven by build-host end-to-end on the same machine
# with quakespasm's DMG before this port wired it in.
install_via_local_mount_fallback() {
  echo "[deploy-dmg $HOST] remote hdiutil attach failed; falling back to local-mount + rsync (old-mac-build-host#41)" >&2
  LMNT="$(mktemp -d "${TMPDIR:-/tmp}/q2install-mnt.XXXXXX")"
  trap 'hdiutil detach "$LMNT" >/dev/null 2>&1 || hdiutil detach -force "$LMNT" >/dev/null 2>&1 || true; rmdir "$LMNT" 2>/dev/null || true' EXIT
  hdiutil attach -nobrowse -readonly -mountpoint "$LMNT" "$DMG" >/dev/null

  DEST_REL="quake2-play"
  ssh "$HOST" "mkdir -p $DEST_REL/baseq2 && rm -f $DEST_REL/baseq2/autoexec.cfg"

  echo "[deploy-dmg $HOST] rsync Quake2.app (local mount -> target, hdiutil bypass)"
  rsync -a --delete -e ssh "$LMNT/Quake2.app/" "$HOST:$DEST_REL/Quake2.app/"
  scp -pq "$LMNT/ref_gl.so" "$HOST:$DEST_REL/ref_gl.so"
  scp -pq "$LMNT/baseq2/game.so" "$HOST:$DEST_REL/baseq2/game.so"
  [ -f "$LMNT/q2ded" ] && scp -pq "$LMNT/q2ded" "$HOST:$DEST_REL/q2ded"

  # Same byte-for-byte standard as the remote path (MISTAKES.md — a corrupt
  # renderer that loaded but misrendered is worse than one that failed loud).
  for f in "Quake2.app/Contents/MacOS/quake2" "ref_gl.so" "baseq2/game.so"; do
    l=$(md5 "$LMNT/$f" 2>/dev/null | awk '{print $NF}')
    r=$(ssh "$HOST" "md5 '$DEST_REL/$f' | awk '{print \$NF}'")
    [ "$l" = "$r" ] || { echo "[deploy-dmg $HOST] FATAL: $f corrupt after rsync fallback ($l != $r)" >&2; exit 7; }
  done
  echo "[deploy-dmg $HOST] [verify] installed binaries match the image byte-for-byte (local-mount fallback) ✅"

  ssh "$HOST" "sh Desktop/clear-launch-quarantine.sh '$DEST_REL/Quake2.app'"
  ssh "$HOST" "file '$DEST_REL/Quake2.app/Contents/MacOS/quake2' 2>/dev/null | sed 's/.*: //'; rm -f Desktop/clear-launch-quarantine.sh"

  hdiutil detach "$LMNT" >/dev/null 2>&1 || hdiutil detach -force "$LMNT" >/dev/null 2>&1 || true
  rmdir "$LMNT" 2>/dev/null || true
  trap - EXIT
}

echo "[deploy-dmg $HOST] mount + install into ~/quake2-play/ (preserving game data)"
if ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE="$1"
MNT="$HOME/q2install-mnt"
DEST="$HOME/quake2-play"

# fresh mountpoint — detach any stale attach, then rmdir (NEVER rm -rf a path
# that might still be a mounted read-only volume).
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
# Exit 42 on attach failure specifically (not whatever hdiutil's own status
# happens to be) so the caller can tell "this host's hdiutil is broken, try
# the local-mount fallback" apart from a real install failure below.
# old-mac-build-host#41: quad-tiger's DiskImages/DiskArbitration stack fails
# to attach ANY disk image — reboot, cold power-cycle, framework-version fix
# all ruled out there, this is not a bug in this script.
if ! hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/Desktop/$DMG_BASE" >/dev/null 2>&1; then
  echo "  hdiutil attach failed on $(hostname -s 2>/dev/null || echo this host)" >&2
  exit 42
fi

mkdir -p "$DEST/baseq2"

# Migration, same as deploy.sh:254-260 — an earlier scheme staged the
# per-machine cfg to baseq2/autoexec.cfg. It now ships inside
# Quake2.app/Contents/Resources/. FS_ExecAutoexec (filesystem.c:1569) reads
# $fs_basedir/baseq2/autoexec.cfg, and basedir is `.` here, so a leftover
# resolves and is queued AFTER the bundle layers finish in Com_Init — it
# would override the shipped overlay on a machine nobody would think to
# check. The disk image never ships one (make-dmg.sh:193 stages only
# game.so into baseq2/), so removing it here can only remove an orphan.
rm -f "$DEST/baseq2/autoexec.cfg"
if [ -e "$DEST/baseq2/autoexec.cfg" ]; then
  echo "  FATAL: could not remove stale baseq2/autoexec.cfg" >&2; exit 7
fi
echo "  [config] no stale baseq2/autoexec.cfg (shipped cfg is the bundle's)"

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

# Strip com.apple.quarantine and re-register with LaunchServices. `ditto`
# above PRESERVES quarantine from whatever carried it on the DMG (a real
# human's browser-downloaded release DMG does), and a readme telling a
# person to run `xattr -dr` by hand is not a fix — issue #35/#34. Local step
# on the target, not piped over ssh (see the script's own header).
[ -x "$HOME/Desktop/clear-launch-quarantine.sh" ] && \
  sh "$HOME/Desktop/clear-launch-quarantine.sh" "$DEST/Quake2.app"

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
rm -f "$HOME/Desktop/clear-launch-quarantine.sh"
REMOTE_EOF
then
  :
else
  status=$?
  if [ "$status" = 42 ]; then
    install_via_local_mount_fallback
  else
    echo "[deploy-dmg $HOST] FATAL: remote install failed (exit $status)" >&2
    exit "$status"
  fi
fi

echo "[deploy-dmg $HOST] done — installed from $DMG_BASE"
