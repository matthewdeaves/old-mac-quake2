#!/usr/bin/env bash
# Build the Linux dedicated-server release from the same yquake2 tree the Mac
# fat binary is built from.
#
# This is a SEPARATE release from the fat Mac app. It ships ELF binaries for
# one Linux architecture, and it is built in a container so the result does not
# depend on whatever happens to be installed on the machine that ran it.
#
# usage: scripts/build-server-linux.sh [--arch x86_64|aarch64] [--version V]
# output: dist/server/quake2-server-<version>-linux-<arch>.tar.gz
#
# Requires Docker (or Colima). No local compiler is used and the host
# architecture does not matter.
#
# WHAT GETS BUILT
#
# Two things, because Quake II splits them:
#
#   q2ded            the server engine. `make server` already exists upstream
#                    and is the same target the Mac build produces.
#   baseq2/game.so   the game logic, which runs SERVER side. This is why the
#                    server needs its own build of it rather than borrowing the
#                    one from the Mac release: it is native code for the CPU
#                    the server runs on, not the CPU the players are on.
#
# The renderer is not built at all. A dedicated server has no video, no audio
# and no SDL, so unlike the Mac build there is nothing here that needs them.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ARCH="x86_64"
VERSION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--arch)    ARCH="${2:?--arch needs a value}"; shift 2 ;;
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "$0: unknown argument: $1" >&2; exit 2 ;;
	esac
done

case "$ARCH" in
	x86_64)  DOCKER_PLATFORM="linux/amd64" ;;
	aarch64) DOCKER_PLATFORM="linux/arm64" ;;
	*) echo "$0: unsupported arch: $ARCH (expected x86_64 or aarch64)" >&2; exit 2 ;;
esac

if [ -z "$VERSION" ]; then
	VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
fi
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
git diff --quiet 2>/dev/null || GIT_DIRTY=" (working tree modified)"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

IMAGE="oldmac-quake2-server-build:deb11"
OUT_DIR="$REPO_ROOT/dist/server"
WORK="$REPO_ROOT/build/server-linux-$ARCH"

echo "[server] quake2 dedicated server"
echo "[server]   arch     : $ARCH ($DOCKER_PLATFORM)"
echo "[server]   version  : $VERSION"
echo "[server]   commit   : $GIT_COMMIT$GIT_DIRTY"

command -v docker >/dev/null 2>&1 || {
	echo "$0: docker not found. Start Colima or Docker Desktop first." >&2; exit 1; }
docker info >/dev/null 2>&1 || {
	echo "$0: the Docker daemon is not responding. Try: colima start" >&2; exit 1; }

mkdir -p "$WORK" "$OUT_DIR"

echo "[server] building container image"
docker build --platform "$DOCKER_PLATFORM" \
	-t "$IMAGE" -f scripts/docker/server-build.Dockerfile scripts/docker >/dev/null

# Build in a copy. The Mac drivers rsync this same directory to the Lion mini
# and run make there, so leaving Linux object files in it would be a way to
# poison a later Mac build.
echo "[server] staging source"
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
tar cf - yquake2 | tar xf - -C "$WORK/src"

cat > "$WORK/build-in-container.sh" <<'CONTAINER_SCRIPT'
#!/bin/sh
set -e
cd /work/src/yquake2

# Hardening.
#
# This binary parses UDP datagrams from strangers, in C written in 1997, and is
# meant to sit on the internet permanently. Debian's gcc gives PIE and NX by
# default and nothing else, so a plain build ships with no stack canaries, no
# FORTIFY_SOURCE and only partial RELRO. These are the difference between a
# memory-safety bug being a crash and being a shell.
#
# Exported, not passed on the command line: the Makefile's CFLAGS is a `:=`
# assignment, so a command-line CFLAGS= would replace -O2 and the warning set
# rather than add to them. EXTRA_CFLAGS is a hook added for exactly this.
#
# No -fPIE or -pie here, unlike the other servers in this family: this build
# produces baseq2/game.so as well as the executable, the shared-library rule
# adds -shared, and -shared with -pie is a contradiction the linker rejects.
# Debian's gcc already defaults executables to PIE, so nothing is lost.
export EXTRA_CFLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2"
export EXTRA_LDFLAGS="-Wl,-z,relro,-z,now -Wl,-z,noexecstack"

echo "[container] building q2ded and baseq2/game.so"
make server game -j"$(nproc)" > /work/build.log 2>&1
MAKE_RC=$?

# waf and make both have a habit of reporting success for a build that did not
# produce anything, so the exit code is checked AND the artifacts are checked.
if [ "$MAKE_RC" -ne 0 ]; then
	echo "[container] make failed:" >&2
	tail -40 /work/build.log >&2
	exit 1
fi
for want in release/q2ded release/baseq2/game.so; do
	if [ ! -f "$want" ]; then
		echo "[container] make reported success but $want is missing" >&2
		tail -40 /work/build.log >&2
		exit 1
	fi
done

strip release/q2ded release/baseq2/game.so 2>/dev/null || true
mkdir -p /work/out/baseq2
cp release/q2ded /work/out/
cp release/baseq2/game.so /work/out/baseq2/

echo "[container] verifying"
file /work/out/q2ded

# Assert the hardening actually landed. Flags get silently dropped by a
# Makefile that stomps the variable carrying them, and the result looks exactly
# like a normal build, so this is checked rather than assumed.
for f in /work/out/q2ded /work/out/baseq2/game.so; do
	readelf -sW "$f" | grep -q "__stack_chk_fail" || {
		echo "[container] no stack canaries in $f" >&2; exit 1; }
	readelf -dW "$f" | grep -q "BIND_NOW" || {
		echo "[container] RELRO is not full in $f" >&2; exit 1; }
	readelf -lW "$f" | grep -q "GNU_STACK.*RWE" && {
		echo "[container] executable stack in $f" >&2; exit 1; }
done
echo "[container] hardening: canaries yes, full RELRO, NX"

# Everything this loads must be part of a base Linux install. glibc plus zlib:
# zlib1g is priority-required on Debian and Ubuntu, so it is present on even a
# minimal server image, which is why it is allowed here and nothing else is.
for f in /work/out/q2ded /work/out/baseq2/game.so; do
	ldd "$f" > /work/ldd.txt 2>&1 || true
	BAD=$(grep -oE '^[[:space:]]*[a-zA-Z0-9_.+-]+\.so[0-9.]*' /work/ldd.txt \
		| tr -d '[:space:]' \
		| grep -vE '^(libc|libm|libdl|libpthread|librt|libz|libgcc_s|ld-linux.*)\.so' || true)
	if [ -n "$BAD" ]; then
		echo "[container] $f depends on libraries outside the base system:" >&2
		echo "$BAD" >&2
		exit 1
	fi
done

# It has to start. yquake2 refuses to run as root by its own check, so the
# probe runs as a normal user, which is how it will be run in production too.
useradd -m -u 1500 q2probe 2>/dev/null || true
mkdir -p /work/probe
chown -R q2probe /work/probe /work/out
# stdbuf, because stdout is a file here rather than a terminal, so libc block
# buffers it and a timeout kill would throw the whole log away unflushed.
su q2probe -c 'cd /work/probe && timeout 8 stdbuf -oL -eL /work/out/q2ded +set dedicated 1 > /work/probe.log 2>&1' || true
if ! grep -q "Yamagi Quake II" /work/probe.log; then
	echo "[container] the server did not start:" >&2
	cat /work/probe.log >&2
	exit 1
fi
echo "[container] startup probe reached engine init"
CONTAINER_SCRIPT
chmod +x "$WORK/build-in-container.sh"

echo "[server] compiling in container"
rm -rf "$WORK/out"
docker run --rm --platform "$DOCKER_PLATFORM" \
	-v "$WORK:/work" -w /work \
	"$IMAGE" /work/build-in-container.sh

[ -f "$WORK/out/q2ded" ] || { echo "$0: no q2ded was produced" >&2; exit 1; }
[ -f "$WORK/out/baseq2/game.so" ] || { echo "$0: no game.so was produced" >&2; exit 1; }

# ---------------------------------------------------------------------- package
STAGE="$WORK/pkg/quake2-server-$VERSION-linux-$ARCH"
rm -rf "$WORK/pkg"
mkdir -p "$STAGE/systemd" "$STAGE/baseq2"

cp "$WORK/out/q2ded"             "$STAGE/q2ded"
cp "$WORK/out/baseq2/game.so"    "$STAGE/baseq2/game.so"
cp "$REPO_ROOT/server/server.cfg"     "$STAGE/server.cfg"
cp "$REPO_ROOT/server/README.md"      "$STAGE/README.md"
cp "$REPO_ROOT/server/q2ded.service"  "$STAGE/systemd/"

cat > "$STAGE/BUILD-INFO.txt" <<EOF
Quake II dedicated server (old-mac-quake2)
==========================================
Version      : $VERSION
Built from   : git $GIT_COMMIT$GIT_DIRTY
Built on     : $BUILD_DATE
Target       : linux-$ARCH
Built against: Debian 11, glibc 2.31

Contents:
  q2ded            the server engine
  baseq2/game.so   the game logic, which runs on the server

Runs on any Linux with glibc 2.31 or newer (Ubuntu 20.04 and up). The only
shared libraries it loads are glibc and zlib, both part of a base install.

Same source tree as the Mac fat binary release. No renderer is built into
this, so it cannot be used as a client.

Project: https://github.com/matthewdeaves/old-mac-quake2
EOF

TARBALL="$OUT_DIR/quake2-server-$VERSION-linux-$ARCH.tar.gz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$WORK/pkg" "$(basename "$STAGE")"
tar tzf "$TARBALL" >/dev/null || { echo "$0: tarball is unreadable" >&2; exit 1; }

echo
echo "[server] done"
echo "[server]   $TARBALL"
echo "[server]   $(du -h "$TARBALL" | cut -f1)  sha256 $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo
tar tzf "$TARBALL" | sed 's/^/[server]   /'
