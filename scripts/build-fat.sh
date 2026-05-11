#!/usr/bin/env bash
# Build a 3-arch universal yquake2 by composing the existing per-target
# builds with `lipo`. Same pattern as the QuakeSpasm sister project's
# scripts/build-fat.sh.
#
# Output: build/q2-fat/
#   quake2              Mach-O universal: ppc750 + ppc7400 + x86_64
#   q2ded               Mach-O universal: ppc750 + ppc7400 + x86_64
#   ref_gl.so           Mach-O universal dylib: 3 slices
#   baseq2/game.so      Mach-O universal dylib: 3 slices
#
# dyld picks the right slice per host CPU subtype, so the same
# Quake2.app bundle runs on G3 Panther, G4 Tiger, and Intel Lion.
#
# usage: scripts/build-fat.sh
# pre:   mini-intel reachable; SDKs installed (10.3.9 + 10.4u + Lion default)
# post:  build/q2-{g3,g4,lion,fat} all present; fat is the deliverable
#
# Why not Apple's single-pass `gcc -arch ppc750 -arch ppc7400 -arch x86_64`:
#   - Three different SDKs (10.3.9, 10.4u, Lion default); gcc takes only
#     one -isysroot per invocation.
#   - Two different compilers (gcc-4.0 for PPC, clang for x86_64).
#   - -mcpu / -maltivec differ between the two PPC slices (no AltiVec
#     on the 750; required on the 7400).
# So we do three separate builds and lipo the results.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Sequential, not parallel — build.sh's flock already serialises, but
# even with the flock the sub-builds would only ever run one at a time.
# Running them as separate scripts.sh g3/g4/lion calls keeps the output
# log straightforward and lets a failure surface immediately.
echo "[build-fat] sub-build 1/3: g3"
scripts/build.sh g3
echo "[build-fat] sub-build 2/3: g4"
scripts/build.sh g4
echo "[build-fat] sub-build 3/3: lion"
scripts/build.sh lion

# All three slices present?
for arch in g3 g4 lion; do
  for art in quake2 q2ded ref_gl.so baseq2/game.so; do
    if [ ! -f "build/q2-$arch/$art" ]; then
      echo "[build-fat] missing build/q2-$arch/$art — sub-build did not produce it" >&2
      exit 1
    fi
  done
done

# lipo lives on macOS, not Ubuntu. Send the three per-target slices to
# mini-intel, fuse there, scp the fat artifacts back. (Keeps the
# toolchain assumption uniform with build.sh and avoids needing
# llvm-lipo locally on the Ubuntu workstation.)
BUILD_HOST="${BUILD_HOST:-mini-intel}"
echo "[build-fat] lipo -create on $BUILD_HOST"
ssh "$BUILD_HOST" 'mkdir -p /tmp/q2-fat-stage && rm -rf /tmp/q2-fat-stage/*'
for arch in g3 g4 lion; do
  rsync -aq build/q2-$arch/ "$BUILD_HOST:/tmp/q2-fat-stage/$arch/"
done

ssh "$BUILD_HOST" 'set -e
  cd /tmp/q2-fat-stage
  mkdir -p fat/baseq2
  for art in quake2 q2ded ref_gl.so; do
    lipo -create g3/$art g4/$art lion/$art -output fat/$art
    echo "[lipo] $art:"; lipo -info fat/$art
  done
  lipo -create g3/baseq2/game.so g4/baseq2/game.so lion/baseq2/game.so -output fat/baseq2/game.so
  echo "[lipo] baseq2/game.so:"; lipo -info fat/baseq2/game.so'

mkdir -p "$REPO_ROOT/build/q2-fat/baseq2"
echo "[build-fat] fetch → build/q2-fat/"
rsync -aq "$BUILD_HOST:/tmp/q2-fat-stage/fat/" "$REPO_ROOT/build/q2-fat/"
ssh "$BUILD_HOST" 'rm -rf /tmp/q2-fat-stage' 2>/dev/null || true

echo "[build-fat] sanity:"
file "$REPO_ROOT/build/q2-fat"/* "$REPO_ROOT/build/q2-fat/baseq2"/* 2>/dev/null | sed "s|$REPO_ROOT/||"
echo "[build-fat] OK"
