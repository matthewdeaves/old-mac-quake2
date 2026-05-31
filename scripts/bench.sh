#!/usr/bin/env bash
# Run a Q2 timedemo benchmark on a target machine.
# Assumes the bundle is already deployed (scripts/deploy.sh first).
#
# usage: scripts/bench.sh <yosemite|sawtooth|quicksilver|mini-g4|imac-g5|mini-intel|imac-2019> <demo> <WxH> [runs]
#   demo:  demo1 | demo2 | demo3   (the .dm2 suffix is added automatically)
#   WxH:   1024x768 | 640x480 | ...
#   runs:  default 3
#
# env:
#   NOTES        free-form annotation appended to the CSV `notes` column,
#                followed by the current commit's subject line. Use this
#                to distinguish "Phase A baseline" from a cherry-pick or
#                experiment. Default: "Phase A baseline".
#   COMMIT       override the recorded commit hash (parallel-bench.sh
#                exports this so a long matrix run tags consistently).
#   EXTRA        extra +cmd "set X Y" tokens appended to the engine
#                cmdline. Used for A/B'ing cvars against the production
#                autoexec without rebuild/redeploy. +cmd executes AFTER
#                the bundle's autoexec hook, so it overrides cleanly.
#                Example: EXTRA='+cmd "set gl_overbrightbits 4"'
#
# CSV columns (results.csv):
#   timestamp     UTC ISO-8601, captured at row-write time
#   commit        short SHA
#   build_type    fat | per-target | unknown — detected on the target
#                 by which layout is in ~/Desktop/quake2/
#   machine       ssh alias (yosemite, quicksilver, ...)
#   cpu / gpu / os    hardcoded per-machine metadata (these are immutable
#                 retro boxes — see the case-statement below for the
#                 source of truth)
#   demo / res    demo file basename, WxH
#   runN_fps      one column per run
#   median_fps    mean(run2,run3) for RUNS>=3 to drop the cold-cache
#                 first run; mean(run1,run2) for RUNS==2; run1 for RUNS==1
#   notes         free-form (NOTES env) | commit subject line
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

# ---- iMac G5 (ATI R300 / Leopard) headless-safety rail ---------------
# The Radeon 9600 (R300) Leopard driver HARD-HANGS the whole OS on a
# fullscreen video-mode SWITCH to a non-native resolution: grey screen,
# no ping, no SSH, fans to max (the SMU thermal failsafe) — recoverable
# ONLY by the physical power button. A same-mode fullscreen request at
# the native panel resolution is a display CAPTURE with no mode change,
# which the driver survives cleanly (QuakeSpasm got 119 fps that way).
# So on the G5 we force fullscreen to the native 1440x900 panel and
# REFUSE any other resolution under fullscreen. Set G5_WINDOWED=1 to
# bench windowed (vid_fullscreen 0) instead — safe at any res and
# recoverable over SSH worst-case; use it for first bring-up.
# Ref: ~/Desktop/imac-g5-leopard-port-notes.md (QuakeSpasm port findings).
# VID_FS = vid_fullscreen, VID_DFS = vid_desktopfullscreen. Both are set
# EXPLICITLY on the cmdline below so the measured mode never depends on a
# leftover config.cfg from a prior production launch (which may have
# archived vid_desktopfullscreen 1 on an iMac).
VID_FS=1
VID_DFS=0
if [ "$TARGET" = "imac-g5" ]; then
  G5_NATIVE_RES="1440x900"   # 17" iMac G5 panel; 20" model would be 1680x1050
  if [ "${G5_WINDOWED:-0}" = "1" ]; then
    VID_FS=0
    echo "[bench imac-g5] WINDOWED (vid_fullscreen 0) — safe at any res, SSH-recoverable"
  elif [ "$RES" != "$G5_NATIVE_RES" ]; then
    echo "[bench imac-g5] REFUSING fullscreen at non-native $RES — the R300 driver" >&2
    echo "  hard-hangs the OS on a non-native mode switch (needs the power button)." >&2
    echo "  Use RES=$G5_NATIVE_RES (native, same-mode capture) or set G5_WINDOWED=1." >&2
    exit 3
  else
    # Native res via the CAPTURE path (vid_desktopfullscreen 1) — guaranteed
    # no mode switch, the only R300-safe fullscreen.
    VID_DFS=1
    echo "[bench imac-g5] native-res same-mode CAPTURE $G5_NATIVE_RES (R300-safe)"
  fi
fi

# Per-machine timeout (timedemo wall-clock budget) and cooldown
# (post-run sleep before next run kicks off). G3 needs minutes for the
# demo + extra cooldown because the Rage 128 driver leaves the display
# LUT in a fragile state for a few seconds after fullscreen exit — back-
# to-back runs without cooldown can hang the machine (in-game audio
# loops, no video signal, hard reboot required). Empirical fix: 5s
# settle time on yosemite, 2s on the G4s, 1s elsewhere.
case "$TARGET" in
  yosemite)    HOST=yosemite;    TIMEOUT=300; COOLDOWN=5 ;;
  sawtooth)    HOST=sawtooth;    TIMEOUT=180; COOLDOWN=3 ;;
  quicksilver) HOST=quicksilver; TIMEOUT=120; COOLDOWN=2 ;;
  mini-g4)     HOST=mini-g4;     TIMEOUT=120; COOLDOWN=2 ;;
  imac-g5)     HOST=imac-g5;     TIMEOUT=90;  COOLDOWN=2 ;;
  mini-intel)  HOST=mini-intel;  TIMEOUT=60;  COOLDOWN=1 ;;
  imac-2019)   HOST=imac-2019;   TIMEOUT=45;  COOLDOWN=1 ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
COMMIT_SUBJECT=$(git -C "$REPO_ROOT" log -1 --format=%s "$COMMIT" 2>/dev/null | tr ',' ';' | head -c 80)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RAW_DIR="$REPO_ROOT/benchmarks/raw"
CSV="$REPO_ROOT/benchmarks/results.csv"
mkdir -p "$RAW_DIR"

# Per-machine hardware/OS metadata. Hardcoded rather than detected on
# every run because (a) these machines are immutable retro hardware,
# (b) `sw_vers` + `sysctl` over ssh adds 6+ remote-shell round trips
# per bench cell, and (c) hardcoding keeps the CSV reproducible — if
# the same row is re-benched on a different box by accident, the
# hardware column won't lie.
case "$TARGET" in
  yosemite)    META_CPU="PPC 750 @ 449MHz";    META_GPU="ATI Rage 128 16MB";          META_OS="10.3.9 Panther" ;;
  sawtooth)    META_CPU="PPC 7400 @ 500MHz";   META_GPU="NVIDIA GeForce2 MX 32MB";    META_OS="10.4.11 Tiger" ;;
  quicksilver) META_CPU="PPC 7450 @ 733MHz";   META_GPU="ATI Radeon 9000 Pro 64MB";   META_OS="10.4.11 Tiger" ;;
  mini-g4)     META_CPU="PPC 7447A @ 1.25GHz"; META_GPU="ATI Radeon 9200 32MB";       META_OS="10.4.11 Tiger" ;;
  imac-g5)     META_CPU="PPC 970FX @ 2.0GHz";  META_GPU="ATI Radeon 9600 128MB";      META_OS="10.5.8 Leopard" ;;
  mini-intel)  META_CPU="Core 2 Duo @ 2.33GHz";META_GPU="Intel GMA 950 64MB";         META_OS="10.7.5 Lion" ;;
  imac-2019)   META_CPU="i5-9600K @ 3.7GHz";   META_GPU="AMD Radeon Pro 580X 8GB";    META_OS="15.7 Sequoia" ;;
esac

# Detect which build flavour is on the host: fat universal binary lives
# inside Quake2.app/Contents/MacOS/; per-target lives in the deploy root.
# Captures the binary's actual Mach-O architectures via `file` so the
# CSV row pins down exactly what was tested.
BUILD_TYPE=$(ssh "$HOST" 'if [ -f ~/Desktop/quake2/Quake2.app/Contents/MacOS/quake2 ]; then
  echo "fat"
elif [ -f ~/Desktop/quake2/quake2 ]; then
  echo "per-target"
else
  echo "unknown"
fi' 2>/dev/null || echo "unknown")

# Notes: caller-supplied free-form context (e.g. NOTES="Phase A baseline").
# Commas are sanitised to semicolons so CSV stays parseable. The commit
# subject is always appended automatically so future-you can read why a
# row exists without having to cross-ref the git log.
NOTES_RAW="${NOTES:-Phase A baseline} | $COMMIT_SUBJECT"
NOTES_CSV=$(echo "$NOTES_RAW" | tr ',' ';' | head -c 200)

# CSV header (initialize once). Atomic via bash noclobber (set -C →
# O_CREAT|O_EXCL), so two parallel bench.sh procs racing on a missing
# CSV produce exactly one header row.
( set -C; echo "timestamp,commit,build_type,machine,cpu,gpu,os,demo,res,run1_fps,run2_fps,run3_fps,median_fps,notes" > "$CSV" ) 2>/dev/null || true

declare -a FPS
for i in $(seq 1 $RUNS); do
  echo "[bench $TARGET $DEMO $RES] run $i/$RUNS"
  # Kill any stale engine before each run. Same gentle TERM-grace-KILL
  # pattern as the sister project's bench.sh — Panther's display LUT
  # corrupts if Quake is hard-killed mid-fullscreen, so always send
  # TERM first so SDL has a chance to restore display state.
  # Poll with integer `sleep 1` — Panther's /bin/sleep is integer-only;
  # fractional sleeps return instantly and would busy-spin.
  # Engine path auto-detect: fat deploys ship Quake2.app/Contents/MacOS/quake2;
  # per-target deploys ship a flat ./quake2 next to the binary. Both are
  # invoked with CWD = ~/Desktop/quake2/ so basedir=. picks up ref_gl.so
  # and baseq2/ in the parent directory either way.
  ssh "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 2; fi
    killall -KILL quake2 2>/dev/null || true
    sleep 1
    cd ~/Desktop/quake2
    rm -f ~/.yq2/baseq2/qconsole.log
    if [ -x ./Quake2.app/Contents/MacOS/quake2 ]; then
      ENGINE=./Quake2.app/Contents/MacOS/quake2
    else
      ENGINE=./quake2
    fi
    \$ENGINE -nolauncher \\
      +set vid_fullscreen $VID_FS +set vid_desktopfullscreen $VID_DFS +set vid_gamma 1 \\
      +set gl_mode -1 +set gl_customwidth $W +set gl_customheight $H \\
      +set gl_swapinterval 0 \\
      +set s_initsound 0 \\
      +set logfile 2 \\
      +set timedemo 1 \\
      ${EXTRA:-} \\
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
    # Post-run cooldown — gives the GPU driver time to restore display
    # state. Critical on yosemite where the Rage 128 LUT can hang the
    # machine if the next run starts before the driver settles.
    sleep $COOLDOWN
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

echo "$TS,$COMMIT,$BUILD_TYPE,$TARGET,$META_CPU,$META_GPU,$META_OS,$DEMO,$RES,${FPS[0]:-NA},${FPS[1]:-NA},${FPS[2]:-NA},$MEDIAN,$NOTES_CSV" >> "$CSV"
echo "[bench] $TARGET ($BUILD_TYPE) $DEMO $RES median = $MEDIAN fps  →  $CSV"

NA=0; for v in "${FPS[@]}"; do [ "$v" = "NA" ] && NA=$((NA+1)); done
if [ "$NA" -gt 0 ]; then
  echo "[bench] FAIL: $NA/${RUNS} run(s) NA on $TARGET $DEMO $RES — see $RAW_DIR/${COMMIT}_${TARGET}_${DEMO}_${RES}_run*.log" >&2
  exit 1
fi
