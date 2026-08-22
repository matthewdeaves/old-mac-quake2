#!/usr/bin/env bash
# Build a yquake2 binary on the cross-build host (mini-intel, Lion).
# - g3/g4/g5: cross-compile PPC via gcc-4.0 + 10.3.9/10.4u/10.5 SDKs
# - lion    : native x86_64 build on the Lion box itself
#
# The build TARGET names (g3/g4/g5/lion) refer to chip family + SDK, NOT
# machine identity (single g4 binary serves sawtooth + quicksilver + mini-g4).
#
# usage: scripts/build.sh <g3|g4|g5|lion|i386>
# output: build/q2-<target>/{quake2, ref_gl.so, baseq2/game.so, q2ded}
# env:    BUILD_HOST (ssh alias; default: auto-picked from the free Intel minis
#         by scripts/pick-build-host.sh)
#         BUILD_HOSTS / BUILD_LOCK_WAIT — see scripts/pick-build-host.sh

set -euo pipefail

# shellcheck source=scripts/source-stamp.sh
. "$(dirname "$0")/source-stamp.sh"
# The exclude list is a PARAMETER of the shared file, supplied per repo.
# shellcheck source=scripts/source-stamp-excludes.sh
. "$(dirname "$0")/source-stamp-excludes.sh"

TARGET="${1:?usage: $0 <g3|g4|g5|lion|i386>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The cross-build host is an Intel Mac mini — there are now TWO interchangeable
# ones (mini-intel, mini-intel2: same Macmini2,1 / 10.7.5 / identical toolchain).
# When the caller has not pinned one, ask pick-build-host.sh for a host that is
# reachable and idle, and CLAIM it for the duration so nothing grabs it mid-build.
# The claim is a lock ON the mini, so it is visible to the QuakeSpasm/Q3/Half-Life
# sister projects too — the flock below only serialises builds from THIS checkout.
# build-fat.sh pins BUILD_HOST for all five mini-built slices, so this only fires for a
# standalone build.sh run.
BUILD_HOST_CLAIMED=0
if [ -z "${BUILD_HOST:-}" ]; then
  # Strict release. Without a nonce the picker can only match user@host:repo,
  # which every session in this repo shares, so a sibling session's --release
  # would silently drop this build's lock -- the case build-host#7 was filed
  # for. Exported, not local, because the EXIT trap below runs --release in a
  # SEPARATE process and has to present the same claim this acquire made.
  export BENCH_LOCK_CLAIM="${BENCH_LOCK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
  BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
    "$REPO_ROOT/scripts/pick-build-host.sh" --acquire "quake2 build.sh $TARGET")" || {
    echo "build.sh: no free Intel build host; see scripts/pick-build-host.sh --status" >&2
    exit 1
  }
  BUILD_HOST_CLAIMED=1
  echo "[build] claimed build host: $BUILD_HOST"
fi
trap '[ "$BUILD_HOST_CLAIMED" = 1 ] && "$REPO_ROOT/scripts/pick-build-host.sh" --release "$BUILD_HOST" >/dev/null 2>&1; true' EXIT

# Serialize concurrent invocations. Both targets rsync to mini-intel:quake2/
# and `make -j` in the same dir — running in parallel races on .o files and
# stamps the binary with the *other* target's CPU subtype (documented in
# CLAUDE.md "Don't run g3 and g4 builds in parallel").
#
# Needs flock(1): native on the Ubuntu workstation; on the macOS workstation
# install it with `brew install flock` (discoteq formula — supports the same
# `flock -w # fd` interface). Without it this errors "command not found".
LOCK_DIR="$REPO_ROOT/build"
mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/.build.lock"
if ! flock -w 600 9; then
  echo "build.sh: another build is in progress on $BUILD_HOST; waited 10 min, giving up" >&2
  exit 1
fi

case "$TARGET" in
  g3)
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3
    # Everything the Makefile injects into both CFLAGS and LDFLAGS rides
    # along via $(OSX_ARCH), since OSX_ARCH is referenced (not assigned)
    # by the Makefile so command-line override is safe. The Makefile uses:
    #   CFLAGS += $(OSX_ARCH)
    #   LDFLAGS := $(OSX_ARCH) -lm     (Darwin)
    #   $(CC) $(OSX_ARCH) -x objective-c  (SDLMain.m rule)
    # so -isysroot/-mmacosx-version-min/-arch/-mcpu/-O3 all need to ride
    # here. -F../MacOSX so the linker finds our fat SDL.framework (cwd
    # during make is mini-intel:quake2/yquake2). -Wl,-w silences cosmetic
    # crt1.o "-mlong-branch no longer needed" warnings on 10.3.9 SDK.
    #
    # NOTE: we deliberately DO NOT pass LDFLAGS= on the make command line.
    # That would block target-specific `LDFLAGS += -lz`/`-framework SDL`
    # appends in the Makefile (command-line vars have higher precedence
    # than Makefile assignments unless `override` is used).
    OSX_ARCH="-arch ppc -isysroot $SDK -mmacosx-version-min=$VMIN -mcpu=750 -O3 -F../MacOSX -Wl,-w"
    ;;
  g4)
    # Built against the 10.3.9 SDK at min-10.3, NOT 10.4u/min-10.4 (issue #1).
    # dyld grades slices by CPU subtype alone — the OS floor plays no part —
    # so a G4 booted on Panther is handed this ppc7400 slice regardless, with
    # no fallback to the min-10.3 ppc750 one. Building it at 10.3 is what makes
    # that machine work; AltiVec codegen is independent of the SDK, so the
    # Tiger G4s lose nothing (A/B benched, see docs/STATUS.md).
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3
    # -faltivec: enables Apple's context-sensitive `vector` keyword, which
    # r_mesh.c's AltiVec lerp path needs. Required against the 10.3.9 SDK and
    # not against 10.4u. It has a nasty side effect — it silently defeats
    # -mcpu=7400's cpusubtype stamping, leaving a generic `ppc (ALL)` slice
    # that the Tiger/Leopard kernel mis-grades on a G3. The post-fetch
    # assert-and-re-stamp block below is what catches that; do not remove it.
    # -isystem <gcc-4.0 include>: r_mesh.c includes <altivec.h>, which is a
    # COMPILER header, not an SDK one — -isysroot hides it.
    OSX_ARCH="-arch ppc -isysroot $SDK -mmacosx-version-min=$VMIN -mcpu=7400 -faltivec -maltivec -mabi=altivec -mtune=7450 -O3 -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include -F../MacOSX -Wl,-w"
    ;;
  g5)
    # iMac G5 (PowerMac8,2, single 970FX @ 2.0 GHz) on Leopard 10.5.8.
    # The 970 has AltiVec (so the __VEC__ code paths apply, same as g4) but
    # a deep, heavily out-of-order pipeline with different AltiVec latencies
    # than the 7450 — so it gets its own -mcpu=970 scheduling pass against
    # the 10.5 SDK rather than reusing the g4 slice.
    #
    # `-arch ppc -mcpu=970` stamps cpusubtype ppc970 (Apple gcc propagates
    # -mcpu into the Mach-O subtype, the same mechanism that gives g4 its
    # ppc7400 stamp), so this is a distinct lipo member: dyld prefers it on
    # the G5, while G4 hosts (ppc7450, not a 970 descendant) fall back to
    # the ppc7400 slice and any G3 runs the ppc750 floor.
    #
    # Apple gcc defines only __VEC__/__ALTIVEC__/__ppc__ for -mcpu=970 (no
    # __ppc970__), so the 970 slice is indistinguishable from the 7400 slice
    # at compile time. -DQ2_ARCH_PPC970 (rides into CFLAGS via OSX_ARCH)
    # gives misc.c a hook to load the generic-G5 autoexec baseline
    # (autoexec-ppc970) FIRST, before the __VEC__ → ppc7400 branch.
    #
    # 32-bit ABI (-arch ppc, not ppc64): Leopard runs the 32-bit slice fine
    # and we have no need for 64-bit GPRs here.
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.5.sdk
    VMIN=10.5
    OSX_ARCH="-arch ppc -isysroot $SDK -mmacosx-version-min=$VMIN -mcpu=970 -maltivec -mabi=altivec -O3 -DQ2_ARCH_PPC970 -F../MacOSX -Wl,-w"
    ;;
  lion)
    # Native x86_64 on Lion. Use clang for modern C support. No -isysroot
    # — let clang use its default (Lion's Xcode 4.6.x SDK).
    #
    # min-10.6, not 10.7 (issue #5). Same slice-grading argument as the G4
    # above: a 64-bit Intel Mac left on Snow Leopard grades to this x86_64
    # slice and has nowhere else to go, so the floor may as well be the
    # oldest the toolchain can emit. Lowering the deployment target only
    # weakens what the linker may assume about the host — the Lion SDK
    # still supplies the headers — and this engine is plain C with no
    # libc++ dependency, so there is nothing here that needs 10.7.
    CC=/usr/bin/clang
    VMIN=10.6
    OSX_ARCH="-arch x86_64 -mmacosx-version-min=$VMIN -O3 -Qunused-arguments -F../MacOSX"
    ;;
  i386)
    # 32-bit-only Intel: the 2006 Core Solo / Core Duo machines (Mac mini 1,1,
    # iMac 4,1, MacBook 1,1, MacBook Pro 1,1). The only Intel Macs with no
    # 64-bit mode, and they stop at 10.6.8.
    #
    # Not a nicety. dyld grades by CPU subtype alone and never falls back, so
    # those machines are never handed the x86_64 slice and, with no i386 slice
    # present, get nothing at all: the app does not launch.
    #
    # min-10.4, lower than the x86_64 slice's 10.6, for the same
    # slice-grading reason applied downward. An i386-only Mac may still be on
    # Tiger or Leopard and there is nothing beneath this slice to catch it.
    # The bundled SDL.framework already carries an i386 slice.
    #
    # NOT TESTED ON HARDWARE: no 32-bit-only Intel Mac exists in the fleet.
    # Build-correct only.
    CC=/usr/bin/clang
    VMIN=10.4
    OSX_ARCH="-arch i386 -mmacosx-version-min=$VMIN -O3 -Qunused-arguments -F../MacOSX"
    ;;
  arm64)
    echo "build.sh: arm64 cannot be built on a Lion mini. Its Xcode 4.6" >&2
    echo "build.sh: toolchain predates arm64 by seven years, and the SDL 1.2" >&2
    echo "build.sh: this engine links has no arm64 build at all. See" >&2
    echo "build.sh: docs/adr/0014 for where that stands." >&2
    exit 2
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4|g5|lion|i386)" >&2
    exit 2
    ;;
esac

# Hard-coded project-local rsync path. Conflating with the QuakeSpasm
# sister project's mini-intel:quakespasm/ would overwrite QS source and
# break both projects (see CLAUDE.md "Multi-tenancy on mini-intel").
REMOTE_PATH="quake2"
case "$REMOTE_PATH" in
  quake2) ;;
  *) echo "build.sh: REMOTE_PATH must be quake2/, got $REMOTE_PATH" >&2; exit 3 ;;
esac

echo "[build] sync sources Ubuntu → $BUILD_HOST:$REMOTE_PATH/"
# Exclude:
#   - .git: huge and irrelevant on build host
#   - reference/: 46 MB of source we only need on workstation for cherry-picks
#   - build/, benchmarks/: workstation-only output
#   - prereqs/: vendored installers, sister-project artifact
# The exclude list lives in scripts/source-stamp-excludes.sh and is passed in, not
# repeated here. The source stamp hashes exactly the set this rsync sends, so the
# two must not drift: a file this excludes cannot affect the build, and a file it
# sends must change the stamp. See issue #17.
# shellcheck disable=SC2046
rsync -a --partial --inplace --delete \
  $(source_stamp_rsync_excludes "$SOURCE_STAMP_EXCLUDES") \
  -e 'ssh -o ServerAliveInterval=15' \
  "$REPO_ROOT/" "$BUILD_HOST:$REMOTE_PATH/" | tail -3

echo "[build] compile $TARGET on $BUILD_HOST (vmin=$VMIN)"
# Build config:
#   WITH_OPENAL=no, WITH_OGG=no, WITH_CDA=no  → no extra deps
#   WITH_RETEXTURING=yes (2026-05)            → jpeg.c uses stb_image
#                                                instead of libjpeg, so
#                                                the no-libjpeg-on-mini-
#                                                intel constraint that
#                                                forced =no is gone.
#                                                Enables hi-res TGA/JPG
#                                                replacement textures
#                                                across all 3 slices.
#   WITH_ZIP=yes                              → libz is in every SDK
#
# Note: WITH_CDA / WITH_OGG / WITH_OPENAL are NOT recognized by the
# Makefile as command-line overrides — they're :=-assigned at the top.
# So we edit the Makefile in-place on the build host via sed before make.
# WITH_RETEXTURING is left at its Makefile default (yes).
ssh "$BUILD_HOST" "cd $REMOTE_PATH && \
  sed -i.bak -e 's/^WITH_CDA:=yes/WITH_CDA:=no/' \
             -e 's/^WITH_OGG:=yes/WITH_OGG:=no/' \
             -e 's/^WITH_OPENAL:=yes/WITH_OPENAL:=no/' \
             yquake2/Makefile && \
  cd yquake2 && \
  make clean >/dev/null 2>&1 || true
  make -j2 \
    CC=$CC \
    OSX_ARCH=\"$OSX_ARCH\" \
    > /tmp/q2-build-$TARGET.log 2>&1
  RC=\$?
  if [ \$RC -ne 0 ]; then echo '--- tail of build log ---'; tail -50 /tmp/q2-build-$TARGET.log; exit \$RC; fi
  ls -la release/"

# ---- stale-artifact guard --------------------------------------------
# Wipe the local output dir BEFORE fetching. Without this, a build that
# fails (or one whose remote `make` silently produced nothing) leaves the
# PREVIOUS run's binaries sitting here, and every downstream check —
# lipo, file, even the cpusubtype assertion below — happily passes on
# yesterday's artifact. That is how a build with the wrong flags gets
# lipo'd into a release: nothing lies, everything just describes a file
# nobody meant to ship. The same reasoning applies on the remote side,
# where build.sh already runs `make clean` before `make`.
#
# Cheap insurance: the fetch that follows is authoritative, so anything
# left here afterwards came from THIS build.
rm -rf "$REPO_ROOT/build/q2-$TARGET"
mkdir -p "$REPO_ROOT/build/q2-$TARGET/baseq2"
echo "[build] fetch → build/q2-$TARGET/"
rsync -a -e 'ssh -o ServerAliveInterval=15' \
  "$BUILD_HOST:$REMOTE_PATH/yquake2/release/" \
  "$REPO_ROOT/build/q2-$TARGET/"

# Record what this slice was built FROM, next to the slice itself. build-fat.sh
# refuses to fuse slices whose stamps disagree. Written after the fetch so it
# only ever describes artifacts that actually arrived.
source_stamp_write "$REPO_ROOT/build/q2-$TARGET" "$(source_stamp_compute "$REPO_ROOT" "$SOURCE_STAMP_EXCLUDES")"
echo "[build] source stamp $(source_stamp_read "$REPO_ROOT/build/q2-$TARGET" | cut -c1-12)"

# ---- cpusubtype assertion + re-stamp ---------------------------------
# dyld and the kernel grade a fat binary's members by CPU SUBTYPE alone.
# A generic `ppc (ALL)` member is graded as a match for every PowerPC host,
# so a fat of [ppc ALL, ppc7400, ppc970] on a G3 under Tiger or Leopard
# mis-grades and refuses to exec — proven on hardware in the sister
# Half-Life port. Panther's laxer 2003 dyld accepts it, which is exactly
# what makes the bug easy to ship without noticing.
#
# Normally -mcpu=750/7400/970 stamps the subtype for us. -faltivec (needed
# by the g4 slice against the 10.3.9 SDK) silently defeats that and emits
# ALL. So we do not trust the compiler: assert the subtype on every Mach-O
# we just fetched and re-stamp the header where it drifted.
#
# The stamp is the 4-byte big-endian cpusubtype field at offset 8 of a thin
# 32-bit big-endian Mach-O header. These are per-target THIN binaries at
# this point (lipo happens later in build-fat.sh), so offset 8 is the real
# header, not a fat-header entry.
case "$TARGET" in
  g3)   WANT_SUBTYPE=9;   WANT_NAME=ppc750  ;;
  g4)   WANT_SUBTYPE=10;  WANT_NAME=ppc7400 ;;
  g5)   WANT_SUBTYPE=100; WANT_NAME=ppc970  ;;
  *)    WANT_SUBTYPE=""                     ;;   # x86_64 needs no coaxing
esac
if [ -n "$WANT_SUBTYPE" ]; then
  for art in quake2 q2ded ref_gl.so baseq2/game.so; do
    BIN="$REPO_ROOT/build/q2-$TARGET/$art"
    [ -f "$BIN" ] || { echo "[build] missing artifact: $BIN" >&2; exit 1; }
    GOT=$(lipo -info "$BIN" | sed 's/.*: //' | tr -d ' ')
    if [ "$GOT" != "$WANT_NAME" ]; then
      echo "[build] $art cpusubtype is '$GOT', re-stamping → $WANT_NAME ($WANT_SUBTYPE)"
      printf "$(printf '\\%03o\\%03o\\%03o\\%03o' 0 0 0 "$WANT_SUBTYPE")" \
        | dd of="$BIN" bs=1 seek=8 count=4 conv=notrunc 2>/dev/null
      GOT=$(lipo -info "$BIN" | sed 's/.*: //' | tr -d ' ')
      [ "$GOT" = "$WANT_NAME" ] || {
        echo "[build] FAILED to stamp $WANT_NAME on $art (got '$GOT')" >&2; exit 1; }
    fi
    echo "[build] cpusubtype OK: $art = $GOT"
  done
fi

echo "[build] artifacts:"
file "$REPO_ROOT/build/q2-$TARGET"/* "$REPO_ROOT/build/q2-$TARGET/baseq2"/* 2>/dev/null | sed 's|'"$REPO_ROOT/"'||'
