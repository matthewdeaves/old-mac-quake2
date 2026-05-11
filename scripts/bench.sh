#!/usr/bin/env bash
# Run a Q2 timedemo benchmark on a target machine.
# Assumes the bundle is already deployed (scripts/deploy.sh first).
#
# usage: scripts/bench.sh <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019> <demo> <WxH> [runs]
#   demo:  demo1 | demo2 | demo3   (the .dm2 suffix is added automatically)
#   WxH:   1024x768 | 640x480 | ...
#   runs:  default 3
#
# Q2 timedemo differs from Q1 in two ways:
#   * demo files have a .dm2 extension and live inside pak0.pak (the
#     baseq2/demos/*.dm2 virtual path), not on disk under demos/
#   * playback is initiated via `demomap demo1.dm2`, not `playdemo demo1`
#   * the fps line is `N frames, X.X seconds: Y.Y fps` (no leading "X
#     seconds" line — single Com_Printf in cl_network.c:311)
#
# Q2's qconsole.log is written by default (logfile cvar default = 1, via
# misc.c:233). No -condebug flag needed — but we still `+set logfile 2`
# to flush after every Com_Printf so the watchdog's grep on the log
# file catches the fps line even if the engine is mid-buffering.
#
# Log path: yquake2 writes qconsole.log to the user's *writable* gamedir,
# which is ~/.yq2/baseq2/qconsole.log (FS_Gamedir() — see
# common/clientserver.c:110, filesystem.c). NOT baseq2/ next to the
# binary, which is read-only as far as the engine is concerned.
#
# Resolution control: 5.11 selects from a fixed mode table via gl_mode
# (0..N). For arbitrary resolutions we use gl_mode=-1 + gl_customwidth +
# gl_customheight (r_main.c:1066-1069 "a bit hackish approach to enable
# custom resolutions").
#
# output: appends row to benchmarks/results.csv
#         saves raw qconsole.log to benchmarks/raw/

set -euo pipefail

TARGET="${1:?usage: $0 <target> <demo> <WxH> [runs]}"
DEMO="${2:?demo (demo1|demo2|demo3)}"
RES="${3:?resolution WxH}"
RUNS="${4:-3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

W="${RES%x*}"; H="${RES#*x}"

# Per-machine timeout (timedemo wall-clock budget). G3 needs minutes;
# Lion is done in seconds. Same scaling rule as the QuakeSpasm sister.
case "$TARGET" in
  yosemite)    HOST=yosemite;    TIMEOUT=300 ;;
  sawtooth)    HOST=sawtooth;    TIMEOUT=180 ;;
  quicksilver) HOST=quicksilver; TIMEOUT=120 ;;
  mini-g4)     HOST=mini-g4;     TIMEOUT=120 ;;
  mini-intel)  HOST=mini-intel;  TIMEOUT=60  ;;
  imac-2019)   HOST=imac-2019;   TIMEOUT=45  ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RAW_DIR="$REPO_ROOT/benchmarks/raw"
CSV="$REPO_ROOT/benchmarks/results.csv"
mkdir -p "$RAW_DIR"
( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV" ) 2>/dev/null || true

declare -a FPS
for i in $(seq 1 $RUNS); do
  echo "[bench $TARGET $DEMO $RES] run $i/$RUNS"
  # Kill any stale engine before each run. Same gentle TERM-grace-KILL
  # pattern as the sister project's bench.sh — Panther's display LUT
  # corrupts if Quake is hard-killed mid-fullscreen, so always send
  # TERM first so SDL has a chance to restore display state.
  # Poll with integer `sleep 1` — Panther's /bin/sleep is integer-only;
  # fractional sleeps return instantly and would busy-spin.
  ssh "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 2; fi
    killall -KILL quake2 2>/dev/null || true
    sleep 1
    cd ~/Desktop/quake2
    rm -f ~/.yq2/baseq2/qconsole.log
    ./quake2 -nolauncher \\
      +set vid_fullscreen 1 +set vid_gamma 1 \\
      +set gl_mode -1 +set gl_customwidth $W +set gl_customheight $H \\
      +set gl_swapinterval 0 \\
      +set logfile 2 \\
      +set timedemo 1 \\
      +demomap $DEMO.dm2 > /dev/null 2>&1 &
    PID=\$!
    j=0
    while [ \$j -lt $TIMEOUT ]; do
      if [ -f ~/.yq2/baseq2/qconsole.log ] && \\
         grep -q 'frames.*seconds.*fps' ~/.yq2/baseq2/qconsole.log 2>/dev/null; then break; fi
      sleep 1; j=\$((j+1))
    done
    killall -TERM quake2 2>/dev/null
    sleep 2
    killall -KILL quake2 2>/dev/null
    wait \$PID 2>/dev/null
    true" 2>&1 | grep -v "^$" | tail -3 || true

  LOG_NAME="${COMMIT}_${TARGET}_${DEMO}_${RES}_run${i}.log"
  scp -q "$HOST:.yq2/baseq2/qconsole.log" "$RAW_DIR/$LOG_NAME" || true
  FPS_VAL=$(grep -E 'frames.*seconds.*fps' "$RAW_DIR/$LOG_NAME" 2>/dev/null | tail -1 | awk -F': ' '{print $2}' | awk '{print $1}' || true)
  FPS+=("${FPS_VAL:-NA}")
  echo "  -> ${FPS_VAL:-NA} fps"
done

# Median rule: drop run1 (cold) if we have 3+ runs.
if [ "$RUNS" -ge 3 ] && [ "${FPS[1]:-NA}" != "NA" ] && [ "${FPS[2]:-NA}" != "NA" ]; then
  MEDIAN=$(awk -v a="${FPS[1]}" -v b="${FPS[2]}" 'BEGIN{printf "%.2f", (a+b)/2}')
elif [ "$RUNS" -eq 2 ] && [ "${FPS[0]:-NA}" != "NA" ] && [ "${FPS[1]:-NA}" != "NA" ]; then
  MEDIAN=$(awk -v a="${FPS[0]}" -v b="${FPS[1]}" 'BEGIN{printf "%.2f", (a+b)/2}')
else
  MEDIAN="${FPS[$((RUNS-1))]:-NA}"
fi

echo "$TS,$COMMIT,$TARGET,$DEMO,$RES,${FPS[0]:-NA},${FPS[1]:-NA},${FPS[2]:-NA},$MEDIAN" >> "$CSV"
echo "[bench] median = $MEDIAN fps  →  $CSV"

NA=0; for v in "${FPS[@]}"; do [ "$v" = "NA" ] && NA=$((NA+1)); done
if [ "$NA" -gt 0 ]; then
  echo "[bench] FAIL: $NA/${RUNS} run(s) NA on $TARGET $DEMO $RES — see $RAW_DIR/${COMMIT}_${TARGET}_${DEMO}_${RES}_run*.log" >&2
  exit 1
fi
