#!/usr/bin/env bash
# Build a distributable .dmg containing the self-contained Quake2.app +
# the runtime-loaded libraries + a user-facing README — the easy way to
# hand the build to the old Macs.
#
# The contents are staged exactly like deploy.sh: the fat 4-arch binary,
# SDL.framework, per-arch + per-machine autoexec cfgs and decal textures
# inside the .app; ref_gl.so / q2ded / baseq2/game.so OUTSIDE it (Q2 resolves those
# via basedir=. — see deploy.sh for the why). Linux has no hdiutil, so a
# Mac (the Panther G3 by default) does the actual hdiutil create; we stage
# on Ubuntu, ship the folder over, build the .dmg there, and fetch it back.
#
# usage: scripts/make-dmg.sh [version-label]
#   version-label: e.g. v2.1.0 (default: short HEAD hash)
#
# env: DMG_HOST  Mac to run hdiutil on. DEFAULT: quicksilver (Tiger 10.4).
#               WHY TIGER, NOT THE G3 OR LION (all empirically tested 2026-05-31):
#                 * Lion's hdiutil writes a UDIF container Panther's 2003-vintage
#                   DiskImageMounter can't parse — "no mountable file systems" on
#                   10.3.9. NO hdiutil flag fixes it: UDZO, uncompressed UDRO, and
#                   an Apple-Partition-Map (-layout SPUD) image all fail to mount
#                   on Panther. So Lion is out for any image that must reach a G3.
#                 * A TIGER-built UDZO mounts on Panther AND everything newer
#                   (old→new compat holds; new→old doesn't). Tiger is the oldest
#                   OS we need for the hdiutil step.
#                 * We do NOT use the 1999 Panther G3 for this: it's the flakiest
#                   hardware in the fleet (non-ECC RAM / 25-yr-old disk — the source
#                   of the 2026-05-31 single-byte-flip that shipped a corrupt G4
#                   slice). The end-to-end content verification below now catches
#                   any such flip on ANY host, but there's no reason to build on
#                   the worst hardware when a healthy Tiger box does the job.
#               The BINARY is always built on Lion (mini-intel) by build-fat.sh;
#               DMG_HOST only runs the hdiutil packaging step on the staged tree.
#               Override DMG_HOST=mini-g4 (also Tiger) if quicksilver is offline.
#
# pre:   build/q2-fat present (scripts/build-fat.sh; built here if missing)
# post:  dist/Quake2-OldMac-<version>.dmg
#
# One .dmg installs on every supported Mac — the fat binary's four slices
# (ppc750 / ppc7400 / ppc970 / x86_64) + the CFBundle per-arch & per-machine
# autoexec layers mean one disk image serves G3 Panther through modern Intel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --short HEAD)}"
# Tiger host → image mounts on Panther→modern (see header). If DMG_HOST is not
# set explicitly, auto-pick the first REACHABLE Tiger box so a powered-off
# quicksilver doesn't break the default — both write Panther-mountable images.
if [ -z "${DMG_HOST:-}" ]; then
  for cand in quicksilver mini-g4; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$cand" true 2>/dev/null; then DMG_HOST="$cand"; break; fi
  done
  DMG_HOST="${DMG_HOST:-quicksilver}"
  echo "[make-dmg] DMG_HOST not set — using reachable Tiger host: $DMG_HOST"
fi
VOLNAME="Quake2 OldMac $VERSION"
OUT="$REPO_ROOT/dist/Quake2-OldMac-$VERSION.dmg"

BUILD_DIR="$REPO_ROOT/build/q2-fat"
if [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "[make-dmg] build/q2-fat missing — building it"
  scripts/build-fat.sh
fi
# Sanity: must be the 4-slice fat, not a stray single-arch binary. We
# assert the architecture COUNT (3→4 once the g5 slice lands) plus the two
# endpoint subtypes whose `file` names are stable across versions
# (ppc_750, x86_64). The authoritative per-slice ppc970 check is lipo -info
# in build-fat.sh; GNU `file`'s name for cpusubtype 100 is less reliable.
if ! file "$BUILD_DIR/quake2" | grep -q '4 architectures' || \
   ! file "$BUILD_DIR/quake2" | grep -q 'ppc_750'         || \
   ! file "$BUILD_DIR/quake2" | grep -q 'x86_64'; then
  echo "[make-dmg] $BUILD_DIR/quake2 is not the 4-arch fat binary (need ppc750+ppc7400+ppc970+x86_64) — run scripts/build-fat.sh" >&2
  exit 1
fi

# ---- stage the disk-image contents (same layout as deploy.sh) ------------
STAGE=$(mktemp -d -t q2-dmg.XXXXXX)
trap "rm -rf '$STAGE'" EXIT
IMG="$STAGE/img"                       # becomes the .dmg root
APP="$IMG/Quake2.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES" "$IMG/baseq2"

echo "[make-dmg] stage Quake2.app (same layout as deploy.sh)"
cp    "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"
cp    "$REPO_ROOT/MacOSX/Quake2.icns"        "$RESOURCES/"
cp -a "$REPO_ROOT/MacOSX/SDL.framework"      "$APP/Contents/MacOS/"
cp    "$BUILD_DIR/quake2"                    "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/quake2"

# Both cfg layers ship inside the bundle: the four per-arch baselines
# (picked at compile time by the fat slice dyld runs) and the six
# per-machine overlays (picked at boot by sysctl hw.model via CFBundle —
# see yquake2/src/common/misc.c).
#
# Shipped COMMENT-STRIPPED — the engine's command buffer is a fixed 8 KB
# (cmd_text_buf[8192]) and the baseline + overlay are appended back-to-back
# before execution, so their combined size must stay well under 8 KB. The
# documentation comments alone blow that budget (→ "Cbuf_AddText: overflow",
# garbled config, R300 GPU wedge on the iMac G5). Same strip as deploy.sh.
for cfg in controls \
           ppc750 ppc7400 ppc970 x86_64 \
           yosemite sawtooth quicksilver mini-g4 imac-g5 mini-intel imac-2019; do
  sed -e 's,//.*,,' -e 's/[[:space:]]*$//' \
      "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" \
    | grep -v '^[[:space:]]*$' \
    > "$RESOURCES/autoexec-$cfg.cfg"
done

# Procedural decal textures, same as deploy.sh (Resources/hd-pak/decals/).
if [ -d "$REPO_ROOT/yquake2/baseq2-extra/decals" ]; then
  mkdir -p "$RESOURCES/hd-pak/decals"
  cp "$REPO_ROOT/yquake2/baseq2-extra/decals/"*.tga "$RESOURCES/hd-pak/decals/"
fi

# ref_gl.so / q2ded / baseq2/game.so ship OUTSIDE the bundle (basedir=.).
cp "$BUILD_DIR/ref_gl.so"      "$IMG/"
cp "$BUILD_DIR/baseq2/game.so" "$IMG/baseq2/"
cp "$BUILD_DIR/q2ded"          "$IMG/" 2>/dev/null || true
[ -f "$IMG/q2ded" ] && chmod +x "$IMG/q2ded"

# ---- user-facing README inside the image ---------------------------------
cat > "$IMG/README.txt" <<EOF
Quake II — Old-Mac fat build ($VERSION)
=======================================

A yquake2 5.11 fork tuned to look as good as possible while staying playable
on retro Macs from 1999 to today. ONE universal binary (PowerPC G3 + PowerPC
G4/AltiVec + PowerPC G5 + Intel x86_64); the right code slice and the right
per-machine visual/perf config are picked automatically at launch.

Supported: Mac OS X 10.3.9 Panther (G3) and up — Tiger (G4), Leopard (G5),
Lion, through modern Intel macOS. (PowerPC G3/G4/G5 and 64-bit Intel only —
pre-Lion 32-bit Intel Macs are not supported.)

INSTALL
-------
1. Make a folder for the game, e.g.  ~/Desktop/quake2/
2. Copy EVERYTHING from this disk image into that folder:
       Quake2.app
       ref_gl.so
       q2ded
       baseq2/        (contains game.so)
3. Add your Quake II data — copy your retail pak files into baseq2/:
       ~/Desktop/quake2/baseq2/pak0.pak              (main game)
       ~/Desktop/quake2/baseq2/pak1.pak  pak2.pak    (3.20 point release)
       ~/Desktop/quake2/baseq2/players/  video/      (skins, cinematics)
   Retail Quake II is on Steam and GOG.
4. Double-click Quake2.app.

The final layout:
   ~/Desktop/quake2/Quake2.app
   ~/Desktop/quake2/ref_gl.so
   ~/Desktop/quake2/q2ded
   ~/Desktop/quake2/baseq2/game.so
   ~/Desktop/quake2/baseq2/pak0.pak (+ pak1, pak2, players/, video/)

MODERN macOS (Gatekeeper)
-------------------------
The bundle is unsigned, so recent macOS will quarantine it. Either right-click
Quake2.app and choose Open the first time, or run:
   xattr -dr com.apple.quarantine ~/Desktop/quake2/Quake2.app
(Not needed on Panther / Tiger / Lion.)

PER-MACHINE CONFIG
------------------
The app detects the Mac it's on (sysctl hw.model) and applies a hand-tuned
visual + performance config — anisotropic filtering, trilinear, alias
drop-shadows, linear fog, world decals, energy-shell glow, lightmapped glass,
water caustics, and more on the machines that can afford them; leaner settings
where they can't. Every knob is a runtime cvar or launch -flag, so nothing is
locked in.

Project: https://github.com/matthewdeaves/old-mac-quake2
License: GPL-2.0-or-later (see the project repo).
EOF

# ---- build the .dmg on a Mac, with END-TO-END content verification -------
# CRITICAL (learned the hard way — see MISTAKES.md 2026-05-31 "DMG byte-flip"):
# `hdiutil verify` only checks the UDIF container's *internal* checksum — that
# the compressed blocks decompress to whatever was stored. It does NOT verify
# that what was stored matches our source. A single byte flipped anywhere in
# the rsync→hdiutil chain (e.g. a bad sector / RAM glitch on the 25-year-old
# Panther G3 we build on) passes `hdiutil verify` and ships a corrupt binary.
# That exact failure turned a register-save (stw r31) in the ppc7400 slice's
# Con_Print into an illegal 64-bit opcode → EXC_PPC_PRIVINST → instant crash
# on every G4, while deploy.sh (which ships build/q2-fat directly, no DMG) was
# fine. So: after building, mount the finished image and md5 the actual
# binaries inside it against the source. Retry on mismatch; fail loud if it
# can't be made clean (never ship a corrupt DMG again).
REMOTE="/tmp/q2-dmg-$VERSION"
# Panther (yosemite) ships rsync 2.5.x — needs --protocol=29, same as deploy.sh.
RSYNC_EXTRA=""
[ "$DMG_HOST" = "yosemite" ] && RSYNC_EXTRA="--protocol=29"

# The corruptible PPC/x86 binaries whose fidelity we assert end-to-end. The
# staged $IMG copies are plain local `cp` of build/q2-fat, so $IMG md5s ARE
# the true-source md5s.
VERIFY_FILES="Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so"
SRC_SUMS=$(cd "$IMG" && for f in $VERIFY_FILES; do \
             printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$f"; done)

mkdir -p "$REPO_ROOT/dist"

attempt=0; verified=no
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  echo "[make-dmg] attempt $attempt/3: ship staged image to $DMG_HOST and run hdiutil"
  ssh "$DMG_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' "$IMG/" "$DMG_HOST:$REMOTE/img/"
  # UDZO = zlib-compressed read-only image; widest compatibility incl. Panther.
  ssh "$DMG_HOST" "rm -f '$REMOTE/out.dmg' && \
    hdiutil create -volname '$VOLNAME' -srcfolder '$REMOTE/img' \
      -ov -format UDZO '$REMOTE/out.dmg' && \
    hdiutil verify '$REMOTE/out.dmg' >/dev/null"

  # md5 the binaries INSIDE the finished image (mount → hash → detach). Mount
  # at a private mountpoint (not /Volumes) to dodge BSD-grep parsing and any
  # stale same-name mount left by a previous run. Tolerant of detach races.
  # NB: the file list is hardcoded in the remote script (NOT passed as args) —
  # ssh runs the command through a remote shell that word-splits on spaces, so
  # a multi-path "$VERIFY_FILES" arg would be silently truncated to its first
  # path. Keep this list in sync with $VERIFY_FILES above.
  DMG_SUMS=$(ssh "$DMG_HOST" bash -s "$REMOTE" <<'REMOTE_EOF' || true
REM="$1"; MP="$REM/mnt"
mkdir -p "$MP"
hdiutil detach "$MP" >/dev/null 2>&1 || true
hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$REM/out.dmg" >/dev/null 2>&1 || exit 7
for f in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so; do
  printf '%s  %s\n' "$(md5 "$MP/$f" 2>/dev/null | awk '{print $NF}')" "$f"
done
hdiutil detach "$MP" >/dev/null 2>&1 || hdiutil detach -force "$MP" >/dev/null 2>&1 || true
REMOTE_EOF
)
  if [ "$DMG_SUMS" = "$SRC_SUMS" ]; then verified=yes; break; fi
  echo "[make-dmg] WARNING: DMG contents differ from source (attempt $attempt) — retrying" >&2
  echo "--- source ---"; echo "$SRC_SUMS"
  echo "--- in dmg ---"; echo "$DMG_SUMS"
done

[ "$verified" = yes ] || {
  echo "[make-dmg] FATAL: could not produce an uncorrupted DMG after $attempt attempts on $DMG_HOST." >&2
  echo "           The build host may have a failing disk/RAM. Try a different DMG_HOST." >&2
  exit 1
}
echo "[make-dmg] verified: quake2 / ref_gl.so / game.so inside the DMG match source byte-for-byte"

# Fetch, then verify scp didn't corrupt the container either.
scp -q "$DMG_HOST:$REMOTE/out.dmg" "$OUT"
RMT_DMG_MD5=$(ssh "$DMG_HOST" "md5 '$REMOTE/out.dmg' | awk '{print \$NF}'")
LCL_DMG_MD5=$(md5sum "$OUT" | cut -d' ' -f1)
[ "$RMT_DMG_MD5" = "$LCL_DMG_MD5" ] || {
  echo "[make-dmg] FATAL: scp corrupted $OUT ($RMT_DMG_MD5 != $LCL_DMG_MD5)" >&2; exit 1; }
ssh "$DMG_HOST" "rm -rf '$REMOTE'" 2>/dev/null || true

echo "[make-dmg] OK — $OUT (contents verified byte-identical to source)"
ls -lh "$OUT"
