#!/usr/bin/env bash
# Build a yquake2 binary on the cross-build host (mini-intel, Lion).
# - g3/g4: cross-compile PPC via gcc-4.0 + 10.3.9/10.4u SDKs
# - lion : native x86_64 build on the Lion box itself
#
# The build TARGET names (g3/g4/lion) refer to chip family + SDK, NOT machine
# identity (single g4 binary serves sawtooth + quicksilver + mini-g4).
#
# usage: scripts/build.sh <g3|g4|lion>
# output: build/q2-<target>/{quake2, ref_gl.so, baseq2/game.so, q2ded}
# env:    BUILD_HOST (ssh alias, default 'mini-intel')

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4|lion>}"
BUILD_HOST="${BUILD_HOST:-mini-intel}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Serialize concurrent invocations. Both targets rsync to mini-intel:quake2/
# and `make -j` in the same dir — running in parallel races on .o files and
# stamps the binary with the *other* target's CPU subtype (documented in
# CLAUDE.md "Don't run g3 and g4 builds in parallel").
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
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.4u.sdk
    VMIN=10.4
    OSX_ARCH="-arch ppc -isysroot $SDK -mmacosx-version-min=$VMIN -mcpu=7400 -maltivec -mabi=altivec -mtune=7450 -O3 -F../MacOSX -Wl,-w"
    ;;
  lion)
    # Native x86_64 on Lion. Use clang for modern C support. No -isysroot
    # — let clang use its default (Lion's Xcode 4.6.x SDK).
    CC=/usr/bin/clang
    VMIN=10.7
    OSX_ARCH="-arch x86_64 -mmacosx-version-min=$VMIN -O3 -Qunused-arguments -F../MacOSX"
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4|lion)" >&2
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
rsync -a --partial --inplace --delete \
  --exclude='.git' --exclude='*.o' --exclude='*.d' \
  --exclude='build/' --exclude='benchmarks/' --exclude='prereqs/' \
  --exclude='reference/' \
  -e 'ssh -o ServerAliveInterval=15' \
  "$REPO_ROOT/" "$BUILD_HOST:$REMOTE_PATH/" | tail -3

echo "[build] compile $TARGET on $BUILD_HOST (vmin=$VMIN)"
# Phase A.1 build config (per PPC_PLAN.md):
#   WITH_OPENAL=no, WITH_OGG=no, WITH_CDA=no  → no extra deps for first build
#   WITH_RETEXTURING=no                       → libjpeg not installed on mini-intel
#                                                (PPC_PLAN.md A.1 says keep ON, but
#                                                 disabling for first build to keep
#                                                 scope minimal; revisit in A.3)
#   WITH_ZIP=yes                              → libz is in every SDK
#
# Note: WITH_CDA / WITH_OGG / WITH_OPENAL / WITH_RETEXTURING are NOT recognized
# by the Makefile as command-line overrides — they're :=-assigned at the top.
# So we edit the Makefile in-place on the build host via sed before make.
ssh "$BUILD_HOST" "cd $REMOTE_PATH && \
  sed -i.bak -e 's/^WITH_CDA:=yes/WITH_CDA:=no/' \
             -e 's/^WITH_OGG:=yes/WITH_OGG:=no/' \
             -e 's/^WITH_OPENAL:=yes/WITH_OPENAL:=no/' \
             -e 's/^WITH_RETEXTURING:=yes/WITH_RETEXTURING:=no/' \
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

mkdir -p "$REPO_ROOT/build/q2-$TARGET/baseq2"
echo "[build] fetch → build/q2-$TARGET/"
rsync -a -e 'ssh -o ServerAliveInterval=15' \
  "$BUILD_HOST:$REMOTE_PATH/yquake2/release/" \
  "$REPO_ROOT/build/q2-$TARGET/"

echo "[build] artifacts:"
file "$REPO_ROOT/build/q2-$TARGET"/* "$REPO_ROOT/build/q2-$TARGET/baseq2"/* 2>/dev/null | sed 's|'"$REPO_ROOT/"'||'
