#!/usr/bin/env bash
# Build a distributable .dmg containing the self-contained Quake2.app +
# the runtime-loaded libraries + a user-facing README — the easy way to
# hand the build to the old Macs.
#
# The contents are staged exactly like deploy.sh: the fat 3-arch binary,
# SDL.framework, per-machine autoexec cfgs and decal textures inside the
# .app; ref_gl.so / q2ded / baseq2/game.so OUTSIDE it (Q2 resolves those
# via basedir=. — see deploy.sh for the why). Linux has no hdiutil, so a
# Mac (the Panther G3 by default) does the actual hdiutil create; we stage
# on Ubuntu, ship the folder over, build the .dmg there, and fetch it back.
#
# usage: scripts/make-dmg.sh [version-label]
#   version-label: e.g. v2.1.0 (default: short HEAD hash)
#
# env: DMG_HOST  Mac to run hdiutil on. DEFAULT: yosemite (the Panther G3).
#               This matters: a UDZO image built by Lion's hdiutil reports
#               "no mountable file systems" on Mac OS X 10.3.9 — the UDIF
#               container version is too new for Panther's DiskImageMounter.
#               An image built on the OLDEST target OS mounts everywhere
#               from 10.3.9 → modern (old→new compat holds; new→old doesn't).
#               Override with DMG_HOST=quicksilver (Tiger) / =mini-intel
#               (Lion) for a faster build if you only ship to Tiger+.
#
# pre:   build/q2-fat present (scripts/build-fat.sh; built here if missing)
# post:  dist/Quake2-OldMac-<version>.dmg
#
# One .dmg installs on every supported Mac — the fat binary's three slices
# (ppc750 / ppc7400 / x86_64) + the CFBundle per-machine autoexec layer mean
# one disk image serves G3 Panther through modern Intel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --short HEAD)}"
DMG_HOST="${DMG_HOST:-yosemite}"   # Panther host → image mounts on every target
VOLNAME="Quake2 OldMac $VERSION"
OUT="$REPO_ROOT/dist/Quake2-OldMac-$VERSION.dmg"

BUILD_DIR="$REPO_ROOT/build/q2-fat"
if [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "[make-dmg] build/q2-fat missing — building it"
  scripts/build-fat.sh
fi
# Sanity: must be the 3-slice fat, not a stray single-arch binary.
if ! file "$BUILD_DIR/quake2" | grep -q 'ppc_750' || \
   ! file "$BUILD_DIR/quake2" | grep -q 'x86_64'; then
  echo "[make-dmg] $BUILD_DIR/quake2 is not the 3-arch fat binary — run scripts/build-fat.sh" >&2
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

# All six per-machine cfgs ship inside the bundle (picked at boot by
# sysctl hw.model via CFBundle — see yquake2/src/common/misc.c).
for cfg in yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019; do
  cp "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" "$RESOURCES/"
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
G4/AltiVec + Intel x86_64); the right code slice and the right per-machine
visual/perf config are picked automatically at launch.

Supported: Mac OS X 10.3.9 Panther (G3) and up, through modern Intel macOS.
(PowerPC G3/G4 and 64-bit Intel only — pre-Lion 32-bit Intel Macs are not
supported.)

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

# ---- build the .dmg on a Mac (hdiutil is macOS-only) ---------------------
REMOTE="/tmp/q2-dmg-$VERSION"
# Panther (yosemite) ships rsync 2.5.x — needs --protocol=29, same as deploy.sh.
RSYNC_EXTRA=""
[ "$DMG_HOST" = "yosemite" ] && RSYNC_EXTRA="--protocol=29"
echo "[make-dmg] ship staged image to $DMG_HOST and run hdiutil"
ssh "$DMG_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a --partial $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' "$IMG/" "$DMG_HOST:$REMOTE/img/"
# UDZO = zlib-compressed read-only image; widest compatibility incl. Panther.
ssh "$DMG_HOST" "rm -f '$REMOTE/out.dmg' && \
  hdiutil create -volname '$VOLNAME' -srcfolder '$REMOTE/img' \
    -ov -format UDZO '$REMOTE/out.dmg' && \
  hdiutil verify '$REMOTE/out.dmg' >/dev/null"

mkdir -p "$REPO_ROOT/dist"
scp -q "$DMG_HOST:$REMOTE/out.dmg" "$OUT"
ssh "$DMG_HOST" "rm -rf '$REMOTE'" 2>/dev/null || true

echo "[make-dmg] OK — $OUT"
ls -lh "$OUT"
