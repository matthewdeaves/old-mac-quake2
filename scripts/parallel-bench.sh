#!/usr/bin/env bash
# Run the bench matrix on every reachable machine concurrently.
# Adapted from the QuakeSpasm sister project's parallel-bench.sh.
#
# Cuts wall time roughly to the slowest leg (G3 yosemite) vs running
# them serially. CSV row appends and raw log filenames are independent
# per machine, so legs never collide.
#
# usage: scripts/parallel-bench.sh [--reset] [--quick] [--no-<machine> ...]
#
#   --reset      starts fresh epoch — backs up results.csv to
#                results.csv.bak.<ts> if non-empty, then wipes
#                results.csv + raw/. Use only when starting a brand
#                new optimization round.
#   --quick      demo1 only × both resolutions × 3 runs (default).
#                demo2 and demo3 fill in only on a non-quick run.
#   --no-<host>  skip a specific machine
#                (yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019)
#
# Env-var overrides (take precedence):
#   DEMOS="demo1"                       default: "demo1 demo2 demo3", or "demo1" with --quick
#   RESES="1024x768 640x480"            default: "1024x768 640x480"
#   RUNS=3                              default: 3
#   NOTES="Phase B group-draw"          appended to each row's notes column
#
# Pre-flight: scripts/deploy.sh fat <machine> for each target.
#
# Safety:
#   - CSV header init in bench.sh is atomic (bash noclobber).
#   - CSV row appends are atomic on Linux/macOS for writes < PIPE_BUF (4 KB);
#     our rows are ~140 B so rows from machines won't interleave.
#   - Raw log filenames include the machine name, so legs never collide.
#   - SSH connections to all hosts are independent.

set -euo pipefail

RESET=0
QUICK=1
declare -A SKIP
for M in yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019; do
  SKIP[$M]=0
done

for arg in "$@"; do
  case "$arg" in
    --reset)            RESET=1 ;;
    --quick)            QUICK=1 ;;
    --full)             QUICK=0 ;;
    --no-yosemite)      SKIP[yosemite]=1 ;;
    --no-sawtooth)      SKIP[sawtooth]=1 ;;
    --no-quicksilver)   SKIP[quicksilver]=1 ;;
    --no-mini-g4)       SKIP[mini-g4]=1 ;;
    --no-mini-intel)    SKIP[mini-intel]=1 ;;
    --no-imac-2019)     SKIP[imac-2019]=1 ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$REPO_ROOT/benchmarks/results.csv"
RAW="$REPO_ROOT/benchmarks/raw"

# Pin commit + subject for the whole grid (bench.sh honors $COMMIT if set,
# else falls back to its own git rev-parse). Without this, a side commit
# during a long parallel run would tag rows inconsistently.
COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
export COMMIT
echo "[parallel-bench] tagging all rows with commit $COMMIT"

if [ "$RESET" -eq 1 ]; then
  if [ -s "$CSV" ] && [ "$(wc -l < "$CSV")" -gt 1 ]; then
    BACKUP="$CSV.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$CSV" "$BACKUP"
    echo "[parallel-bench] --reset: backed up existing results.csv → $BACKUP"
  fi
  rm -rf "$RAW"
  mkdir -p "$RAW"
  rm -f "$CSV"
  echo "[parallel-bench] --reset: wiped raw/ and results.csv (fresh epoch)"
fi

# Active legs — order is fastest to slowest, so the wall-time tail
# corresponds to the long-pole G3.
ALL_LEGS=(imac-2019 mini-intel quicksilver mini-g4 sawtooth yosemite)
ACTIVE_LEGS=()
for LEG in "${ALL_LEGS[@]}"; do
  if [ "${SKIP[$LEG]}" -eq 0 ]; then
    # Liveness probe so we don't burn 10 minutes waiting for an offline
    # box to time out. 5s connect timeout is plenty on a wired LAN.
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$LEG" true 2>/dev/null; then
      ACTIVE_LEGS+=("$LEG")
    else
      echo "[parallel-bench] $LEG unreachable — skipping"
    fi
  fi
done

if [ "${#ACTIVE_LEGS[@]}" -eq 0 ]; then
  echo "[parallel-bench] no reachable legs — nothing to do" >&2
  exit 2
fi

if [ "$QUICK" -eq 1 ]; then
  DEMOS="${DEMOS:-demo1}"
  RESES="${RESES:-1024x768 640x480}"
  RUNS="${RUNS:-3}"
  LABEL="quick"
else
  DEMOS="${DEMOS:-demo1 demo2 demo3}"
  RESES="${RESES:-1024x768 640x480}"
  RUNS="${RUNS:-3}"
  LABEL="full"
fi
export DEMOS RESES RUNS

echo "[parallel-bench] mode=$LABEL  legs=${ACTIVE_LEGS[*]}  demos=$DEMOS  reses=$RESES  runs=$RUNS"

# Pre-flight: stale-process kill on every active machine in parallel.
# TERM-grace-KILL pattern — Tiger's Quartz LUT can get stuck if Q2 is
# hard-killed mid-fullscreen, same gotcha as the QuakeSpasm sister.
echo "[parallel-bench] pre-flight: clearing stale quake2 processes"
for LEG in "${ACTIVE_LEGS[@]}"; do
  ssh -o ConnectTimeout=5 "$LEG" 'if killall -TERM quake2 2>/dev/null; then sleep 2; fi
    killall -KILL quake2 2>/dev/null || true' &
done
wait

# Launch each leg as a background full-bench-style matrix sweep over
# its own subprocess. Each call to bench.sh writes its row directly to
# the shared CSV; small atomic appends + per-machine raw log filenames
# mean no inter-leg interference.
LOG_DIR="/tmp/q2-parallel-bench-logs"
mkdir -p "$LOG_DIR"
declare -A LEG_PID LEG_RC LEG_LOG
for LEG in "${ACTIVE_LEGS[@]}"; do
  LEG_LOG[$LEG]="$LOG_DIR/${LEG}.log"
done

echo "[parallel-bench] start: $(date)"
for LEG in "${ACTIVE_LEGS[@]}"; do
  (
    for R in $RESES; do
      for D in $DEMOS; do
        "$REPO_ROOT/scripts/bench.sh" "$LEG" "$D" "$R" "$RUNS"
      done
    done
  ) > "${LEG_LOG[$LEG]}" 2>&1 &
  LEG_PID[$LEG]=$!
  printf "[parallel-bench] %-12s pid=%s  log=%s\n" "$LEG" "${LEG_PID[$LEG]}" "${LEG_LOG[$LEG]}"
done

# Wait for every leg, capturing rc — we want the partial CSV either way.
for LEG in "${ACTIVE_LEGS[@]}"; do
  RC=0
  wait "${LEG_PID[$LEG]}" || RC=$?
  LEG_RC[$LEG]=$RC
done

echo "[parallel-bench] done: $(date)"
echo "[parallel-bench] leg exit codes:"
for LEG in "${ACTIVE_LEGS[@]}"; do
  printf "  %-12s rc=%s\n" "$LEG" "${LEG_RC[$LEG]}"
done

echo
echo "=== rows for $COMMIT ==="
{ head -1 "$CSV"; grep ",$COMMIT," "$CSV" || true; } | column -t -s,

ANY_FAIL=0
for LEG in "${ACTIVE_LEGS[@]}"; do
  [ "${LEG_RC[$LEG]}" -ne 0 ] && ANY_FAIL=1
done
[ "$ANY_FAIL" -ne 0 ] && exit 1 || exit 0
