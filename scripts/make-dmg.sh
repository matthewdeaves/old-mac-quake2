#!/usr/bin/env bash
# Build a distributable .dmg containing the self-contained Quake2.app +
# the runtime-loaded libraries + a user-facing README — the easy way to
# hand the build to the old Macs.
#
# The contents are staged exactly like deploy.sh: the fat multi-arch binary,
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
# One .dmg installs on every supported Mac — the fat binary's six slices
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
  # Ask the picker, do not probe. This used to ssh each candidate in turn and
  # take the first that ANSWERED, which is a second picker living in this repo
  # and it graded on the wrong property: reachable is not free. It would happily
  # select a box another session was mid-bench on. Issue #18.
  for cand in quicksilver mini-g4; do
    if [ "$("$REPO_ROOT/scripts/pick-bench-host.sh" --status "$cand" 2>/dev/null | awk 'NR>1{print $2}')" = free ]; then
      DMG_HOST="$cand"; break
    fi
  done
  if [ -z "${DMG_HOST:-}" ]; then
    echo "[make-dmg] no free Tiger G4 (quicksilver, mini-g4)" >&2
    echo "[make-dmg] see: scripts/pick-bench-host.sh --status quicksilver mini-g4" >&2
    exit 1
  fi
  echo "[make-dmg] DMG_HOST not set — picker says free: $DMG_HOST"
fi

# Claim it for the whole packaging run. Same re-exec pattern as bench.sh:103-107;
# `--run` ties the lock to the invocation so it is released however this exits.
#
# This drives a Tiger G4 over ssh and rsync at ten call sites and held none of
# them under a claim. Packaging is long, so it was the gap most likely to be
# sitting on a box someone else wanted. Issue #18.
#
# --status above is advisory and can go stale between the check and the claim.
# That is fine: the claim below is the authority, and losing that race fails
# loudly here rather than proceeding onto a machine someone else holds.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
# Compared against the target, not tested for emptiness: a step targeting a
# DIFFERENT machine must still claim it. Issue #19.
if [ "${RETRO_BENCH_LOCK:-}" != "$DMG_HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$DMG_HOST" DMG_HOST
	exec "$_PICK" --run "$DMG_HOST" "make-dmg" -- "$0" "$@"
fi
VOLNAME="Quake2 OldMac $VERSION"
OUT="$REPO_ROOT/dist/Quake2-OldMac-$VERSION.dmg"

BUILD_DIR="$REPO_ROOT/build/q2-fat"
if [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "[make-dmg] build/q2-fat missing — building it"
  scripts/build-fat.sh
fi
# Sanity: must be the 4-slice fat, not a stray single-arch binary. Use lipo
# (reads the Mach header directly) rather than file(1): file's ppc subtype
# names vary by host/toolchain — on an Apple-silicon workstation it renders
# the ppc750 slice as "ppc_650", so the old `file | grep ppc_750` check
# spuriously failed on a good fat. lipo -archs is authoritative.
ARCHS=$(lipo -archs "$BUILD_DIR/quake2" 2>/dev/null || echo)
for a in ppc750 ppc7400 ppc970 i386 x86_64; do
  case " $ARCHS " in
    *" $a "*) ;;
    *) echo "[make-dmg] $BUILD_DIR/quake2 is missing the $a slice (got: ${ARCHS:-none}), run scripts/build-fat.sh" >&2; exit 1;;
  esac
done
# arm64 is REPORTED, not asserted. It cannot be cross-built on a mini, so
# requiring it would make a release impossible from the normal build path, and
# its absence is a Rosetta 2 downgrade rather than a fault. Reporting it is the
# point: a release must never be quietly short a slice. docs/adr/0015.
case " $ARCHS " in
  *" arm64 "*) echo "[make-dmg] arm64 slice present: native on Apple Silicon" ;;
  *)           echo "[make-dmg] NO arm64 slice: Apple Silicon will use Rosetta 2" ;;
esac

# ---- stage the disk-image contents (same layout as deploy.sh) ------------
STAGE=$(mktemp -d -t q2-dmg.XXXXXX)
trap "rm -rf '$STAGE'" EXIT
IMG="$STAGE/img"                       # becomes the .dmg root
APP="$IMG/Quake2.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES" "$IMG/baseq2"

echo "[make-dmg] stage Quake2.app (same layout as deploy.sh)"
cp    "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"

# Stamp the PORT release version into the bundle (same as deploy.sh) so the
# installed build is identifiable from Finder's Get Info. The static plist's
# 5.11 is upstream's engine version and never changes between our releases.
# $VERSION here is the release label the DMG is named after, so the bundle
# and the disk image can never disagree about which build this is.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 5.11-oldmac-$VERSION" \
  -c "Add :CFBundleVersion string $VERSION" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 5.11-oldmac-$VERSION" \
  -c "Set :CFBundleVersion $VERSION" \
  "$APP/Contents/Info.plist" >/dev/null
echo "[make-dmg] bundle version: 5.11-oldmac-$VERSION"

cp    "$REPO_ROOT/MacOSX/Quake2.icns"        "$RESOURCES/"
cp -a "$REPO_ROOT/MacOSX/SDL.framework"      "$APP/Contents/MacOS/"
cp    "$BUILD_DIR/quake2"                    "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/quake2"

# The arm64 member of that framework is sdl12-compat, which dlopen()s a real
# SDL2 at runtime and looks beside the executable for it. Ship ours so that is
# what it finds rather than whatever SDL2 the machine happens to have. The
# other five members are genuine SDL 1.2 and never open this file, so on
# PowerPC and Intel it is inert. Optional, like the arm64 slice itself.
if [ -f "$BUILD_DIR/libSDL2-2.0.0.dylib" ]; then
  cp "$BUILD_DIR/libSDL2-2.0.0.dylib" "$APP/Contents/MacOS/"
  echo "[make-dmg] bundled libSDL2-2.0.0.dylib for the arm64 slice"
else
  case " $ARCHS " in
    *" arm64 "*) echo "[make-dmg] WARNING: arm64 slice present but no libSDL2-2.0.0.dylib to go with it; it will not start" >&2 ;;
  esac
fi

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
           ppc750 ppc7400 ppc970 i386 x86_64 arm64 \
           yosemite sawtooth quicksilver mini-g4 imac-g5 imac-g4 mini-intel imac-2019; do
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
on retro Macs from 1999 to today. ONE universal binary carrying SIX code
slices; the right slice and the right per-machine visual/perf config are both
picked automatically at launch.

WHICH MAC OS EACH CPU NEEDS
---------------------------
dyld picks a slice by CPU alone — the OS floor plays no part in the choice, so
a Mac running an OS older than its slice needs gets that slice anyway and won't
launch. The real floors:

   G3 (750)                 10.3.9 Panther or later
   G4 (7400/7450/7447A)     10.3.9 Panther or later
   G5 (970)                 10.5 Leopard  — a G5 on 10.3/10.4 is NOT supported
   Intel, 32-bit (i386)     10.4 Tiger or later
   Intel, 64-bit (x86_64)   10.6 Snow Leopard or later
   Apple Silicon (arm64)    11 Big Sur or later

Three of those are built but untested: no G4 on Panther, no Intel Mac on Snow
Leopard and no 32-bit Intel Mac exist in the test fleet. They should work;
nobody has proven it.

The i386 slice covers the 2006 Core Solo and Core Duo Macs, the only Intel
Macs with no 64-bit mode. Apple Silicon runs its own native arm64 slice, not
Rosetta 2.

INSTALL
-------
1. Make a folder for the game. On Panther through Lion anywhere will do, e.g.
   ~/Desktop/quake2/. On Apple Silicon and recent macOS use /Applications/quake2/
   instead, for the reason in APPLE SILICON AND MODERN macOS below.
2. Copy EVERYTHING from this disk image into that folder:
       Quake2.app
       ref_gl.so
       q2ded
       baseq2/        (contains game.so)
3. Add your Quake II data — copy your retail pak files and player models:
       ~/Desktop/quake2/baseq2/pak0.pak              (required — main game data)
       ~/Desktop/quake2/baseq2/pak1.pak  pak2.pak    (3.20 point release)
       ~/Desktop/quake2/baseq2/players/              (REQUIRED for player models
                                                      and skins — copy the whole
                                                      players/ folder from your
                                                      retail install. Without it
                                                      multiplayer models will be
                                                      missing or invisible.)
       ~/Desktop/quake2/baseq2/video/                (cinematics — optional)
   Retail Quake II is on Steam and GOG. The players/ folder is inside your
   retail baseq2/ directory alongside the pak files.
4. Double-click Quake2.app.

The final layout:
   ~/Desktop/quake2/Quake2.app
   ~/Desktop/quake2/ref_gl.so
   ~/Desktop/quake2/q2ded
   ~/Desktop/quake2/baseq2/game.so
   ~/Desktop/quake2/baseq2/pak0.pak (+ pak1, pak2, players/, video/)

APPLE SILICON AND MODERN macOS
------------------------------
Put the game folder in /Applications, i.e. /Applications/quake2/, and run it
from there.

That is not a style preference. macOS grants privacy permissions against a
program's identity and location, and a game folder sitting on the Desktop or
in Documents is inside a protected location, so every launch re-asks for
access to it. /Applications is outside those locations, so the prompts stop.

The bundle is ad-hoc signed, which gives it a stable identity for the same
reason. Downloaded copies still carry the quarantine flag, so the first launch
needs either a right-click and Open, or:
   xattr -dr com.apple.quarantine /Applications/quake2/Quake2.app
(Not needed on Panther / Tiger / Lion.)

Do not upgrade by copying the new files over an old install with cp. macOS
caches the code-signature validation of the file that was there before, and the
replacement then fails page validation and is killed at load with
"CODESIGNING / Invalid Page". Delete the old Quake2.app, ref_gl.so, q2ded and
baseq2/game.so first, or drag them to the Trash in Finder, then copy the new
ones in. Your pak files and saves are untouched either way.

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
# ---- ad-hoc code-sign the staged bundle ----------------------------------
# macOS on arm64 refuses to map a page whose code signature does not validate
# and kills the process with CODESIGNING / Invalid Page. An INVALID signature is
# worse than none: unsigned code gets an implicit ad-hoc identity, broken code
# is rejected. Signing also gives the bundle a stable identity, so macOS stops
# re-asking for Desktop/Documents access on every single launch.
#
# Order is not optional: codesign validates a bundle's nested code when it signs
# the bundle, so anything inside must already be signed. Plain dylibs first,
# then each framework as a DIRECTORY (never by its inner binary path), then the
# .app last. Signed here rather than on DMG_HOST, which is a Tiger G4 with no
# codesign, and before SRC_SUMS so the byte verification hashes what ships.
if command -v codesign >/dev/null 2>&1; then
	echo "[make-dmg] ad-hoc code-signing the staged bundle"
	SAPP="$IMG/Quake2.app"
	find "$SAPP" -type f -name '*.dylib' -not -path '*.framework/*' -print0 2>/dev/null \
	  | while IFS= read -r -d '' f; do codesign --force --sign - "$f" >/dev/null 2>&1 || true; done
	for fw in "$SAPP"/Contents/MacOS/*.framework; do
		[ -d "$fw" ] || continue
		# Only symlinks and Versions/ may live at a framework root, or codesign
		# refuses it with "unsealed contents present in the root directory".
		for stray in "$fw"/*; do
			[ -L "$stray" ] && continue
			[ "$(basename "$stray")" = "Versions" ] && continue
			mkdir -p "$fw/Versions/A/Resources"
			mv "$stray" "$fw/Versions/A/Resources/" 2>/dev/null || true
		done
		codesign --force --sign - "$fw" >/dev/null 2>&1 || true
	done
	codesign --force --sign - "$SAPP" >/dev/null 2>&1 || true
	# The loose payload beside the .app is dlopen'd, so it needs signing too.
	for loose in "$IMG"/ref_gl.so "$IMG"/q2ded "$IMG"/baseq2/game.so; do
		[ -f "$loose" ] && codesign --force --sign - "$loose" >/dev/null 2>&1 || true
	done
	codesign -v "$SAPP" >/dev/null 2>&1 || {
		echo "[make-dmg] FATAL: the .app bundle signature does not validate" >&2; exit 1; }
	echo "[make-dmg] signatures verified on the bundle"
else
	echo "[make-dmg] WARN: no codesign here; the bundle will NOT run on Apple Silicon" >&2
fi

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
