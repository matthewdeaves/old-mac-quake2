#!/usr/bin/env bash
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
. scripts/q2-launch.sh
trap 'q2_stop "$HOST" >/dev/null 2>&1 || true; ssh "$HOST" "rm -f /Applications/Quake2/baseq2/vmshot.cfg" >/dev/null 2>&1 || true' EXIT INT TERM
ssh "$HOST" 'mkdir -p ~/.yq2/baseq2; : > ~/.yq2/baseq2/qconsole.log'
ssh "$HOST" bash <<'REMOTE'
set -e
cd /Applications/Quake2
[ ! -e baseq2/vmshot.cfg ] || { echo 'vmshot.cfg already exists' >&2; exit 2; }
{
    i=0; while [ $i -lt 3000 ]; do echo wait; i=$((i+1)); done
    echo 'echo VM_CAPTURE_READY'
    i=0; while [ $i -lt 900 ]; do echo wait; i=$((i+1)); done
    echo quit
} > baseq2/vmshot.cfg
REMOTE
# launch-game.sh refuses (rc 3) if any game is already running on the VM (#108).
q2_launch "$HOST" 900 +set basedir . +set vid_ref gl \
    +set gl_mode -1 +set gl_customwidth 1024 +set gl_customheight 768 \
    +set vid_fullscreen 1 +set vid_desktopfullscreen 0 +set logfile 2 \
    +set timedemo 0 +set cl_maxfps 60 +demomap demo1.dm2 +exec vmshot.cfg \
    || { echo 'Launch refused or failed (a game may already be running); nothing captured.' >&2; exit 2; }
CAPTURED=0
for _ in $(seq 1 150); do
    ssh "$HOST" "kill -0 $Q2_PID" 2>/dev/null || break
    if ssh "$HOST" 'grep -q VM_CAPTURE_READY ~/.yq2/baseq2/qconsole.log'; then
        scripts/shared.sh qemu-vm.sh screendump "$OUT"
        CAPTURED=1
        break
    fi
    sleep 1
done
# The cfg ends in `quit`: give the engine a normal exit, then confirm with TERM-only stop.
for _ in $(seq 1 90); do ssh "$HOST" "kill -0 $Q2_PID" 2>/dev/null || break; sleep 1; done
q2_stop "$HOST" || { echo 'Engine did not exit; NOT sending KILL, quit it by hand.' >&2; exit 1; }
[ "$CAPTURED" = 1 ] && [ -s "$OUT" ] || { echo 'No gameplay frame captured' >&2; exit 1; }
echo "Captured $OUT; engine exited normally. Inspect the image for rendering faults."
