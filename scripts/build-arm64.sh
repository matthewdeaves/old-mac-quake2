#!/usr/bin/env bash
#
# build-arm64.sh - build the Quake II arm64 (Apple Silicon) slice.
#
# RUNS HERE, on the orchestration Mac, NOT on a build mini. This is the one
# slice a mini cannot produce: their Xcode 4.6 toolchain predates arm64 by
# seven years. The other five targets cross-compile on Lion via scripts/build.sh.
#
# Produces all FOUR shipped Mach-O products, the same set build.sh produces for
# every other slice: quake2, q2ded, ref_gl.so and baseq2/game.so.
#
# The SDL problem, and how this slice solves it
# ---------------------------------------------
# This engine links SDL 1.2, which has no arm64 build. So the arm64 slice links
# sdl12-compat, which reimplements the 1.2 API on top of SDL2, and we supply
# the SDL2 as well.
#
# That is a two-layer stack we own end to end, not the four-layer one a package
# manager gives you. sdl12-compat has NO link-time dependency on SDL2 at all:
# it dlopen()s one at runtime, and among the locations it tries is
# "@executable_path/libSDL2-2.0.0.dylib" (SDL12_compat.c, the dylib_locations
# table). Because we ship our own real SDL2 next to the binary, that is what it
# finds, and a system SDL2 never enters the picture.
#
# PowerPC and Intel are untouched. dyld grades a fat by CPU subtype alone, so
# those four members of MacOSX/SDL.framework stay genuine SDL 1.2; only the
# arm64 member is the shim. docs/adr/0015.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/source-stamp.sh
. "$(dirname "$0")/source-stamp.sh"
OUT="$REPO_ROOT/build/arm64"
VMIN="${Q2_ARM64_MIN:-11.0}"
PREFIX="${Q2_ARM64_PREFIX:-$HOME/.cache/oldmac-q2-arm64}"

SDL2_VER="${Q2_ARM64_SDL2_VER:-2.32.4}"
SDL12_URL="https://github.com/libsdl-org/sdl12-compat.git"
SDL12_TAG="${Q2_ARM64_SDL12_TAG:-release-1.2.76}"

command -v cmake >/dev/null 2>&1 || { echo "build-arm64.sh: needs cmake" >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || {
  echo "build-arm64.sh: needs an Apple Silicon Mac (uname -m says $(uname -m))" >&2; exit 1; }

mkdir -p "$OUT" "$PREFIX"

# --- 0) a real SDL2, from source ---------------------------------------------
SDL2_WANT="SDL2 $SDL2_VER arm64 $VMIN"
if [ "$(cat "$PREFIX/.sdl2-built-from" 2>/dev/null)" != "$SDL2_WANT" ]; then
  echo "==> [0/4] building SDL $SDL2_VER (arm64, macOS $VMIN)"
  rm -rf "$PREFIX/sdl2"
  SRC="$PREFIX/src/SDL2-$SDL2_VER"
  if [ ! -d "$SRC" ]; then
    mkdir -p "$PREFIX/src"
    curl -fsSL "https://www.libsdl.org/release/SDL2-$SDL2_VER.tar.gz" | tar xz -C "$PREFIX/src"
  fi
  # Shared, not static: the shim dlopen()s it by name, so a static archive
  # would be unreachable. Built out of tree so a changed floor cannot inherit
  # a previous configure cache.
  rm -rf "$SRC/build-arm64" && mkdir -p "$SRC/build-arm64"
  ( cd "$SRC/build-arm64" && CFLAGS="-arch arm64 -mmacosx-version-min=$VMIN -O2" \
      LDFLAGS="-arch arm64 -mmacosx-version-min=$VMIN" \
      ../configure --prefix="$PREFIX/sdl2" --build=arm64-apple-darwin \
        --enable-shared --disable-static >/dev/null )
  ( cd "$SRC/build-arm64" && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
  printf '%s\n' "$SDL2_WANT" > "$PREFIX/.sdl2-built-from"
fi
SDL2_DYLIB="$PREFIX/sdl2/lib/libSDL2-2.0.0.dylib"
test -f "$SDL2_DYLIB" || { echo "build-arm64.sh: no $SDL2_DYLIB after build" >&2; exit 1; }

# --- 1) sdl12-compat, from source --------------------------------------------
SDL12_WANT="sdl12-compat $SDL12_TAG arm64 $VMIN"
if [ "$(cat "$PREFIX/.sdl12-built-from" 2>/dev/null)" != "$SDL12_WANT" ]; then
  echo "==> [1/4] building sdl12-compat $SDL12_TAG (arm64, macOS $VMIN)"
  SRC12="$PREFIX/src/sdl12-compat"
  [ -d "$SRC12/.git" ] || git clone -q "$SDL12_URL" "$SRC12"
  ( cd "$SRC12" && git fetch -q --tags && git checkout -q "$SDL12_TAG" )
  rm -rf "$SRC12/build-arm64"
  cmake -S "$SRC12" -B "$SRC12/build-arm64" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$VMIN" \
    -DCMAKE_BUILD_TYPE=Release -DSDL12TESTS=OFF -DSDL12DEVEL=OFF >/dev/null
  cmake --build "$SRC12/build-arm64" -j"$(sysctl -n hw.ncpu)" >/dev/null
  rm -rf "$PREFIX/sdl12" && mkdir -p "$PREFIX/sdl12"
  cp "$SRC12/build-arm64/libSDL-1.2.0.dylib" "$PREFIX/sdl12/"
  printf '%s\n' "$SDL12_WANT" > "$PREFIX/.sdl12-built-from"
fi

# If the shim ever gains a link-time SDL2, the "we control both layers"
# argument above stops being true, so assert it rather than trusting it.
if otool -L "$PREFIX/sdl12/libSDL-1.2.0.dylib" | tail -n +2 | grep -qi 'SDL2'; then
  echo "build-arm64.sh: the shim link-depends on SDL2; it must dlopen it instead" >&2
  otool -L "$PREFIX/sdl12/libSDL-1.2.0.dylib" | sed 's/^/    /' >&2
  exit 1
fi

# --- 2) stage the framework this build links against -------------------------
# The engine links -framework SDL out of MacOSX/, so the framework it sees must
# already carry an arm64 member. The committed one does; this re-fuses it from
# the shim just built, so a bumped SDL12_TAG actually takes effect rather than
# silently linking whatever was committed.
echo "==> [2/4] staging SDL.framework with a fresh arm64 member"
FW="$REPO_ROOT/MacOSX/SDL.framework/Versions/A/SDL"
test -f "$FW" || { echo "build-arm64.sh: no $FW" >&2; exit 1; }
TMPSHIM="$OUT/.sdl12-arm64.dylib"
cp "$PREFIX/sdl12/libSDL-1.2.0.dylib" "$TMPSHIM"
chmod u+w "$TMPSHIM"
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" "$TMPSHIM"
strip -x "$TMPSHIM"
# Sign BEFORE the fuse, never after: build-fat.sh lipos on a Lion mini, which
# cannot codesign arm64, and an unsigned arm64 Mach-O is SIGKILLed on load with
# no diagnostic. lipo preserves each member's bytes, signature included.
codesign --force --sign - "$TMPSHIM"
OTHERS=$(lipo -archs "$FW" | tr ' ' '\n' | grep -v '^arm64$' | tr '\n' ' ')
# shellcheck disable=SC2086
lipo "$FW" -remove arm64 -output "$OUT/.sdl-noarm.dylib" 2>/dev/null || cp "$FW" "$OUT/.sdl-noarm.dylib"
lipo -create "$OUT/.sdl-noarm.dylib" "$TMPSHIM" -output "$FW"
echo "    SDL.framework members: $(lipo -archs "$FW")  (was: $OTHERS + shim)"
rm -f "$OUT/.sdl-noarm.dylib"

# --- 3) the engine, all four products ----------------------------------------
# WITH_CDA / WITH_OGG / WITH_OPENAL are :=-assigned at the top of the Makefile,
# so they are NOT overridable from the command line. build.sh sed-edits them on
# the build host; we do the same here, on a copy, so the working tree is never
# left modified if this script dies partway.
echo "==> [3/4] building quake2, q2ded, ref_gl.so, game.so (arm64, macOS $VMIN)"
MK="$REPO_ROOT/yquake2/Makefile"
cp "$MK" "$OUT/.Makefile.orig"
trap 'cp "$OUT/.Makefile.orig" "$MK" 2>/dev/null; rm -f "$OUT/.Makefile.orig"; true' EXIT
sed -i.bak -e 's/^WITH_CDA:=yes/WITH_CDA:=no/' \
           -e 's/^WITH_OGG:=yes/WITH_OGG:=no/' \
           -e 's/^WITH_OPENAL:=yes/WITH_OPENAL:=no/' "$MK"
rm -f "$MK.bak"

( cd "$REPO_ROOT/yquake2" && make clean >/dev/null 2>&1 || true )
( cd "$REPO_ROOT/yquake2" && make -j"$(sysctl -n hw.ncpu)" \
    CC=/usr/bin/clang \
    OSX_ARCH="-arch arm64 -mmacosx-version-min=$VMIN -O2 -Qunused-arguments -F../MacOSX" )

REL="$REPO_ROOT/yquake2/release"
for f in quake2 q2ded ref_gl.so baseq2/game.so; do
  test -f "$REL/$f" || { echo "build-arm64.sh: make produced no $REL/$f" >&2; exit 1; }
done

# --- 4) stage, sign, verify ---------------------------------------------------
rm -rf "$OUT/release" && mkdir -p "$OUT/release/baseq2"
cp "$REL/quake2" "$REL/q2ded" "$REL/ref_gl.so" "$OUT/release/"
cp "$REL/baseq2/game.so" "$OUT/release/baseq2/"
cp "$SDL2_DYLIB" "$OUT/release/libSDL2-2.0.0.dylib"
chmod u+w "$OUT/release/libSDL2-2.0.0.dylib"
install_name_tool -id "@executable_path/libSDL2-2.0.0.dylib" "$OUT/release/libSDL2-2.0.0.dylib"
strip -x "$OUT/release/libSDL2-2.0.0.dylib"

echo "==> [4/4] sign and verify"
for f in "$OUT/release/quake2" "$OUT/release/q2ded" "$OUT/release/ref_gl.so" \
         "$OUT/release/baseq2/game.so" "$OUT/release/libSDL2-2.0.0.dylib"; do
  codesign --force --sign - "$f"
  codesign --verify --verbose=1 "$f"
  GOT=$(lipo -info "$f" | sed 's/.*: //' | tr -d ' ')
  [ "$GOT" = "arm64" ] || { echo "build-arm64.sh: $(basename "$f") is '$GOT', want 'arm64'" >&2; exit 1; }
  echo "    $(basename "$f")  $GOT"
done

# The client must reference the framework by the same install name the other
# five slices use, or dyld looks for a file that is not there.
otool -L "$OUT/release/quake2" | grep -q '@executable_path/SDL.framework/Versions/A/SDL' || {
  echo "build-arm64.sh: client does not reference @executable_path/SDL.framework/..." >&2
  otool -L "$OUT/release/quake2" | sed 's/^/    /' >&2; exit 1; }

# This driver compiles IN PLACE, with no rsync to a build host, so there is no
# transferred file set to hash. It stamps the same local tree the Lion slices
# stamp, which is why the stamp is defined over the source and not over the
# transfer. arm64 is the only slice a fat build never rebuilds, so this stamp is
# the one that actually matters. See issue #17.
source_stamp_write "$OUT/release" "$(source_stamp_compute "$REPO_ROOT")"
echo "==> source stamp $(source_stamp_read "$OUT/release" | cut -c1-12)"

echo "==> done -> build/arm64/release/"
echo "    quake2 q2ded ref_gl.so baseq2/game.so libSDL2-2.0.0.dylib"
echo "    fuse with scripts/build-fat.sh"
