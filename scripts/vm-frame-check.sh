#!/bin/sh
# Host framebuffer smoke capture; not the deterministic check-frames baseline.
# Usage: scripts/vm-frame-check.sh [output.png]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
HOST=qemu-tiger3d
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ]; then
    exec scripts/shared.sh pick-bench-host.sh --run "$HOST" vm-frame-check -- "$0" "$@"
fi
OUT=${1:-/tmp/quake2-vm-gameplay.png}
if ssh "$HOST" 'ps -axc -o ucomm | grep -E "^(quake2|quakespasm|ioquake3|xash3d|xash3d.bin|Aleph One) *$"'; then
    echo 'A game is already running; quit it before capturing.' >&2
    exit 2
fi
ssh "$HOST" 'mkdir -p ~/.yq2/baseq2; : > ~/.yq2/baseq2/qconsole.log'
ssh "$HOST" bash <<'REMOTE' &
set -e
cd /Applications/Quake2
[ ! -e baseq2/vmshot.cfg ] || { echo 'vmshot.cfg already exists' >&2; exit 2; }
trap 'rm -f baseq2/vmshot.cfg' EXIT
{
    i=0; while [ $i -lt 3000 ]; do echo wait; i=$((i+1)); done
    echo 'echo VM_CAPTURE_READY'
    i=0; while [ $i -lt 900 ]; do echo wait; i=$((i+1)); done
    echo quit
} > baseq2/vmshot.cfg
./Quake2.app/Contents/MacOS/quake2 +set basedir . +set vid_ref gl \
    +set gl_mode -1 +set gl_customwidth 1024 +set gl_customheight 768 \
    +set vid_fullscreen 1 +set vid_desktopfullscreen 0 +set logfile 2 \
    +set timedemo 0 +set cl_maxfps 60 +demomap demo1.dm2 +exec vmshot.cfg
REMOTE
SESSION_PID=$!
CAPTURED=0
for _ in $(seq 1 150); do
    kill -0 "$SESSION_PID" 2>/dev/null || break
    if ssh "$HOST" 'grep -q VM_CAPTURE_READY ~/.yq2/baseq2/qconsole.log'; then
        scripts/shared.sh qemu-vm.sh screendump "$OUT"
        CAPTURED=1
        break
    fi
    sleep 1
done
wait "$SESSION_PID"
[ "$CAPTURED" = 1 ] && [ -s "$OUT" ] || { echo 'No gameplay frame captured' >&2; exit 1; }
echo "Captured $OUT; engine exited normally. Inspect the image for rendering faults."
