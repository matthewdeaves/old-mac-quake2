#!/usr/bin/env bash
# Build a 4-arch universal yquake2 by composing the existing per-target
# builds with `lipo`. Same pattern as the QuakeSpasm sister project's
# scripts/build-fat.sh.
#
# Output: build/q2-fat/
#   quake2              Mach-O universal: ppc750 + ppc7400 + ppc970 + x86_64
#   q2ded               Mach-O universal: ppc750 + ppc7400 + ppc970 + x86_64
#   ref_gl.so           Mach-O universal dylib: 4 slices
#   baseq2/game.so      Mach-O universal dylib: 4 slices
#
# dyld picks the right slice per host CPU subtype, so the same Quake2.app
# bundle runs on G3 Panther, G4 Tiger, G5 Leopard, and Intel Lin/modern.
#
# usage: scripts/build-fat.sh
# pre:   mini-intel reachable; SDKs installed (10.3.9 + 10.4u + 10.5 + Lion default)
# post:  build/q2-{g3,g4,g5,lion,fat} all present; fat is the deliverable
#
# Why not Apple's single-pass `gcc -arch ppc750 -arch ppc7400 ...`:
#   - Four different SDKs (10.3.9, 10.4u, 10.5, Lion default); gcc takes
#     only one -isysroot per invocation.
#   - Two different compilers (gcc-4.0 for PPC, clang for x86_64).
#   - -mcpu / -maltivec differ between the three PPC slices (no AltiVec
#     on the 750; required on the 7400 and 970, with distinct scheduling).
# So we do four separate builds and lipo the results.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/source-stamp.sh
. "$(dirname "$0")/source-stamp.sh"
cd "$REPO_ROOT"

# Pin ONE Intel build host for the whole fat build and claim it up front, so all
# four sub-builds and the final lipo use the same mini and no sister project
# (QuakeSpasm/Q3/Half-Life) takes the box between slices. An explicit BUILD_HOST
# from the caller always wins.
if [ -z "${BUILD_HOST:-}" ]; then
  BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
    "$REPO_ROOT/scripts/pick-build-host.sh" --acquire "quake2 build-fat")" || {
    echo "[build-fat] no free Intel build host; see scripts/pick-build-host.sh --status" >&2
    exit 1
  }
  export BUILD_HOST
  # Absolute path: the trap must still resolve if anything ever cd's away.
  trap '"$REPO_ROOT/scripts/pick-build-host.sh" --release "$BUILD_HOST" >/dev/null 2>&1; true' EXIT
  echo "[build-fat] claimed build host: $BUILD_HOST (held for all five mini-built slices + lipo)"
else
  export BUILD_HOST
  echo "[build-fat] using caller-supplied build host: $BUILD_HOST"
fi

# Sequential, not parallel — build.sh's flock already serialises, but
# even with the flock the sub-builds would only ever run one at a time.
# Running them as separate scripts.sh g3/g4/lion calls keeps the output
# log straightforward and lets a failure surface immediately.
echo "[build-fat] sub-build 1/5: g3"
scripts/build.sh g3
echo "[build-fat] sub-build 2/5: g4"
scripts/build.sh g4
echo "[build-fat] sub-build 3/5: g5"
scripts/build.sh g5
echo "[build-fat] sub-build 4/5: lion"
scripts/build.sh lion
echo "[build-fat] sub-build 5/5: i386"
scripts/build.sh i386

# All five cross-built slices present?
for arch in g3 g4 g5 lion i386; do
  for art in quake2 q2ded ref_gl.so baseq2/game.so; do
    if [ ! -f "build/q2-$arch/$art" ]; then
      echo "[build-fat] missing build/q2-$arch/$art - sub-build did not produce it" >&2
      exit 1
    fi
  done
done

# arm64 is OPTIONAL. No mini can cross-build it (their Xcode 4.6 predates it by
# seven years), so it comes from scripts/build-arm64.sh run on the orchestration
# Mac, and its absence is a Rosetta 2 downgrade rather than a fault. Say which of
# the two happened either way: a release must never be quietly short a slice.
ARCHES="g3 g4 g5 lion i386"
ARM64_DIR="$REPO_ROOT/build/arm64/release"
HAVE_ARM64=0
if [ -d "$ARM64_DIR" ]; then
  HAVE_ARM64=1
  for art in quake2 q2ded ref_gl.so baseq2/game.so; do
    [ -f "$ARM64_DIR/$art" ] || HAVE_ARM64=0
  done
fi
if [ "$HAVE_ARM64" = 1 ]; then
  # Staged under the same build/q2-<arch>/ naming the fuse loop below expects,
  # so arm64 needs no special case there.
  rm -rf "$REPO_ROOT/build/q2-arm64"
  mkdir -p "$REPO_ROOT/build/q2-arm64/baseq2"
  cp "$ARM64_DIR/quake2" "$ARM64_DIR/q2ded" "$ARM64_DIR/ref_gl.so" "$REPO_ROOT/build/q2-arm64/"
  cp "$ARM64_DIR/baseq2/game.so" "$REPO_ROOT/build/q2-arm64/baseq2/"
  # Carry the stamp across too. arm64 is the ONLY slice staged by copying: the
  # other five are built in place by build.sh, which writes SOURCE-STAMP into
  # build/q2-<arch>/ itself. Copying only the four artifacts left the staged
  # directory with no stamp, so the gate below read empty and refused EVERY
  # six-slice build, current ones included - on the one slice the gate exists
  # for. Not copied if absent: the gate's "no SOURCE-STAMP, rebuild it" is the
  # right answer for an arm64 tree built before stamps existed.
  if [ -f "$ARM64_DIR/SOURCE-STAMP" ]; then
    cp "$ARM64_DIR/SOURCE-STAMP" "$REPO_ROOT/build/q2-arm64/SOURCE-STAMP"
  fi
  ARCHES="$ARCHES arm64"
  echo "[build-fat] arm64 slice present: fusing SIX"
else
  echo "[build-fat] NO arm64 slice (build/arm64/release incomplete or absent): fusing FIVE"
  echo "[build-fat] Apple Silicon will run the x86_64 slice under Rosetta 2."
  echo "[build-fat] Run scripts/build-arm64.sh on the orchestration Mac to include it."
fi

# lipo lives on macOS, not Ubuntu. Send the three per-target slices to
# mini-intel, fuse there, scp the fat artifacts back. (Keeps the
# toolchain assumption uniform with build.sh and avoids needing
# llvm-lipo locally on the Ubuntu workstation.)
# BUILD_HOST was pinned (and claimed) at the top of this script, so the lipo runs
# on the SAME mini that built the slices. Assert rather than re-defaulting: a second
# "${BUILD_HOST:-mini-intel}" here could silently fuse on a different box than the
# one the slices were staged to.
# ---- refuse to fuse slices built from different source ----------------
#
# The bug this exists for: the arm64 check above tests that the files EXIST. It
# does not test that they are CURRENT. arm64 is the only slice no mini can build,
# so it is produced separately and is the only slice a fat build never rebuilds.
# On 2026-08-22 this fused an arm64 slice three hours older than the source every
# other slice came from, printed "fusing SIX", and exited OK. lipo -archs was
# correct, the slice count was correct, and one slice was missing the fix. #17
#
# Existence, mtime, commit id and commit-id-plus-dirty were all ruled out first;
# scripts/source-stamp.sh records why. This compares content.
WANT_STAMP="$( source_stamp_compute "$REPO_ROOT" )"
echo "[build-fat] source stamp $( echo "$WANT_STAMP" | cut -c1-12 )"
STAMP_BAD=0
for arch in $ARCHES; do
  got="$( source_stamp_read "$REPO_ROOT/build/q2-$arch" )"
  if [ -z "$got" ]; then
    echo "[build-fat] !! build/q2-$arch has no SOURCE-STAMP" >&2
    echo "[build-fat]    rebuild it; it predates the stamp or was staged by hand" >&2
    STAMP_BAD=1
  elif [ "$got" != "$WANT_STAMP" ]; then
    echo "[build-fat] !! build/q2-$arch was built from $( echo "$got" | cut -c1-12 )" >&2
    echo "[build-fat]    the tree is now      $( echo "$WANT_STAMP" | cut -c1-12 )" >&2
    if [ "$arch" = arm64 ]; then
      echo "[build-fat]    re-run scripts/build-arm64.sh on this Mac, then fuse again" >&2
    else
      echo "[build-fat]    re-run scripts/build.sh $arch, then fuse again" >&2
    fi
    STAMP_BAD=1
  fi
done
if [ "$STAMP_BAD" = 1 ]; then
  echo "[build-fat] refusing to fuse: not every slice was built from this source" >&2
  exit 1
fi
echo "[build-fat] all $( set -- $ARCHES; echo $# ) slices built from the same source"

: "${BUILD_HOST:?internal error: build host should have been pinned above}"
echo "[build-fat] lipo -create on $BUILD_HOST ($ARCHES)"
ssh "$BUILD_HOST" 'mkdir -p /tmp/q2-fat-stage && rm -rf /tmp/q2-fat-stage/*'
for arch in $ARCHES; do
  rsync -aq build/q2-$arch/ "$BUILD_HOST:/tmp/q2-fat-stage/$arch/"
done

# Lion's lipo WRITES an arm64 member correctly but cannot NAME it, so a six-way
# fuse prints "cputype (16777228)" for that member in the [lipo] lines below.
# Cosmetic. The naming check that matters runs back on this box, after the fetch.
ssh "$BUILD_HOST" "set -e
  cd /tmp/q2-fat-stage
  mkdir -p fat/baseq2
  for art in quake2 q2ded ref_gl.so; do
    lipo -create \$(for a in $ARCHES; do printf '%s ' \"\$a/\$art\"; done) -output fat/\$art
    echo \"[lipo] \$art:\"; lipo -info fat/\$art
  done
  lipo -create \$(for a in $ARCHES; do printf '%s ' \"\$a/baseq2/game.so\"; done) -output fat/baseq2/game.so
  echo '[lipo] baseq2/game.so:'; lipo -info fat/baseq2/game.so"

mkdir -p "$REPO_ROOT/build/q2-fat/baseq2"
echo "[build-fat] fetch → build/q2-fat/"
rsync -aq "$BUILD_HOST:/tmp/q2-fat-stage/fat/" "$REPO_ROOT/build/q2-fat/"
ssh "$BUILD_HOST" 'rm -rf /tmp/q2-fat-stage' 2>/dev/null || true

if [ "$HAVE_ARM64" = 1 ]; then
  cp "$ARM64_DIR/libSDL2-2.0.0.dylib" "$REPO_ROOT/build/q2-fat/libSDL2-2.0.0.dylib" 2>/dev/null || true
fi

echo "[build-fat] sanity:"
file "$REPO_ROOT/build/q2-fat"/* "$REPO_ROOT/build/q2-fat/baseq2"/* 2>/dev/null | sed "s|$REPO_ROOT/||"

# Gate every product on carrying the same member set, compared as a SET rather
# than as an ordered string: lipo lists members in the order they were fused,
# not in any canonical order, so an ordered compare asserts the argument order
# of the lipo call rather than the contents of the file.
if command -v lipo >/dev/null 2>&1; then
  WANT_SET=$(for a in $ARCHES; do
      case $a in g3) echo ppc750;; g4) echo ppc7400;; g5) echo ppc970;;
                 lion) echo x86_64;; *) echo "$a";; esac
    done | LC_ALL=C sort | tr '\n' ' ')
  for art in quake2 q2ded ref_gl.so baseq2/game.so; do
    GOT_SET=$(lipo -archs "$REPO_ROOT/build/q2-fat/$art" | tr ' ' '\n' | grep . | LC_ALL=C sort | tr '\n' ' ')
    [ "$GOT_SET" = "$WANT_SET" ] || {
      echo "[build-fat] $art has members '$GOT_SET', want '$WANT_SET'" >&2; exit 1; }
    case " $GOT_SET " in
      *" ppc "*) echo "[build-fat] $art has a generic ppc member, which every PowerPC host would match" >&2; exit 1;;
    esac
  done
  echo "[build-fat] all four products carry: $WANT_SET"
fi
# Carry the agreed stamp into the fused output. Up to here it lived only in the
# per-slice staging dirs, so once build/q2-fat existed nothing in it said what it
# came from and make-dmg.sh had to take the build on trust. The value written is
# the one every slice was just verified against.
source_stamp_write "$REPO_ROOT/build/q2-fat" "$WANT_STAMP"
echo "[build-fat] fat stamped $( echo "$WANT_STAMP" | cut -c1-12 )"
echo "[build-fat] OK"
