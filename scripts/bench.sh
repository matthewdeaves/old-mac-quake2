#!/usr/bin/env bash
# Run a Q2 timedemo benchmark on a target machine.
# Assumes the bundle is already deployed (scripts/deploy.sh first).
#
# usage: scripts/bench.sh <yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|imac-g5|g5-tiger|g5-panther|g5-desktop|quad-tiger|quad-leopard|mini-intel|imac-2019> <demo> <WxH> [runs]
#   yosemite-tiger is the SAME Mac as yosemite on its 10.4 partition — one
#   OS is booted at a time, so the two are never both live. Same for the
#   three g5-* tower aliases (one PowerMac G5 Dual 2.7, one OS booted at a
#   time) and the two quad-* aliases (one PowerMac G5 Quad).
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
#   EXTRA        extra +set tokens appended to the engine cmdline. Used for
#                A/B'ing cvars against the production autoexec without a
#                rebuild or redeploy.
#                Example: EXTRA='+set gl_overbrightbits 4'
#
#                USE +set, NOT +cmd. This block used to say +cmd "set X Y",
#                which is the Quake 1 / Half-Life spelling. In Quake II `cmd`
#                FORWARDS ITS TEXT TO THE SERVER (Cmd_ForwardToServer), so it
#                never touches a local cvar. An EXTRA built that way is not an
#                error and prints no warning: the engine starts, the demo
#                runs, a plausible number comes out, and both legs of the A/B
#                have silently measured the shipped config. That is how the
#                2026-06-06 stencil rows came to be believed. See issue #7.
#
#                +set works because Qcommon_Init applies the command-line
#                early commands a SECOND time, at misc.c:500
#                (Cbuf_AddEarlyCommands(true)), which runs AFTER the bundle's
#                per-arch autoexec block. So an explicit +set overrides the
#                production default, which is what the autoexec's own comment
#                at misc.c:365 promises.
#
#                Sanity-check any A/B before believing it: run one leg with a
#                cvar that MUST move the frame rate, and confirm it does. Not
#                gl_picmip, which needs a vid_restart to take effect.
#   BENCH_CSV    override the output CSV path. Default benchmarks/results.csv
#                is git-tracked and every row is meant to be committed with
#                the narrated decision it supports (old-mac-build-host#15: an
#                automated caller with nobody curating a commit per row
#                should point this at a gitignored path instead).
#   BENCH_RAW_DIR override the raw qconsole.log directory. Default
#                benchmarks/raw/ is ALSO git-tracked (old-mac-build-host#28);
#                redirect this alongside BENCH_CSV, not just the CSV alone.
#
# CSV columns (results.csv):
#   timestamp     UTC ISO-8601, captured at row-write time
#   commit        short SHA
#   build_type    fat | per-target | unknown — detected on the target
#                 by which layout is in ~/quake2-play/
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

# Claim this machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK names the machine claimed further up the chain, which is what
# stops the re-exec below recursing. Compare it against the target rather than
# testing whether it is set: a step that targets a DIFFERENT machine still has
# to claim that one, and the emptiness test skipped it silently. Issue #19.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$TARGET"
	exec "$_PICK" --run "$TARGET" "bench" -- "$0" "$@"
fi
DEMO="${2:?demo (demo1|demo2|demo3)}"
RES="${3:?resolution WxH}"
RUNS="${4:-3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

W="${RES%x*}"; H="${RES#*x}"

# Reject a malformed resolution instead of silently benching nonsense.
# On 2026-06-06 nine runs were recorded with RES="1" — almost certainly
# `bench.sh mini-g4 demo1 1` meant as "1 run". The parameter expansions above
# then yielded W=1 H=1, so the engine rendered a 1x1 pixel frame and reported
# 108-128 fps. Those numbers went into docs/STATUS.md and the machine configs
# as evidence that stencil shadows cost only ~15% and sat "well above the
# floor". The real figure at 1024x768 is 38.8 fps. A bench that measures the
# wrong thing is worse than no bench: it gets quoted.
case "$RES" in
  [0-9]*x[0-9]*) ;;
  *) echo "bench.sh: resolution must be WxH (e.g. 1024x768), got '$RES'" >&2
     echo "  usage: $0 <target> <demo> <WxH> [runs]  — runs is the FOURTH arg" >&2
     exit 2 ;;
esac

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
  # Same PowerMac1,1 as `yosemite`, booted from its Tiger partition — same
  # IP, one OS at a time. Same Rage 128 fragility, so the same 5s cooldown.
  yosemite-tiger)
               HOST=yosemite-tiger; TIMEOUT=300; COOLDOWN=5 ;;
  sawtooth)    HOST=sawtooth;    TIMEOUT=180; COOLDOWN=3 ;;
  quicksilver) HOST=quicksilver; TIMEOUT=120; COOLDOWN=2 ;;
  mini-g4)     HOST=mini-g4;     TIMEOUT=120; COOLDOWN=2 ;;
  imac-g5)     HOST=imac-g5;     TIMEOUT=90;  COOLDOWN=2 ;;
  # G5-tower aliases (issue #61): were entirely missing from this case, so
  # every G5-tower bench number already in this repo's history (#33's
  # g5-tiger bloom legs, #54/#60's flashblend/dynamic legs) was taken by
  # hand, not through this script. Deliberately NOT wrapped in the
  # imac-g5 R300 hang guard above — that guard is specific to the R300 +
  # Leopard driver combo on the iMac G5 chassis. g5-tiger has been
  # fullscreen-benched at native res repeatedly without incident (Radeon
  # 9600 RV351 + Tiger 10.4.11, a different GPU/driver/OS combo), so
  # copying an unproven gate here would be adding a gate without proving
  # the passing side (commands.md). TIMEOUT/COOLDOWN match imac-g5's
  # other G5-era numbers, unbenched independently — revisit if a run
  # times out.
  g5-tiger)    HOST=g5-tiger;    TIMEOUT=90;  COOLDOWN=2 ;;
  g5-panther)  HOST=g5-panther;  TIMEOUT=90;  COOLDOWN=2 ;;
  g5-desktop)  HOST=g5-desktop;  TIMEOUT=90;  COOLDOWN=2 ;;
  # G5 Quad aliases — same tower-bench reasoning, different physical box
  # (NVIDIA GeForce 6600, not ATI). No R300 guard applies here either.
  quad-tiger)   HOST=quad-tiger;   TIMEOUT=90; COOLDOWN=2 ;;
  quad-leopard) HOST=quad-leopard; TIMEOUT=90; COOLDOWN=2 ;;
  mini-intel)  HOST=mini-intel;  TIMEOUT=60;  COOLDOWN=1 ;;
  imac-2019)   HOST=imac-2019;   TIMEOUT=45;  COOLDOWN=1 ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# The bench fleet is SHARED — multiple Claude agents (this Q2 port + the
# QuakeSpasm Q1 sister project) drive the same Macs. A second game on a box
# already running one corrupts the measurement and can wedge a fullscreen box.
# Bail if anything Quake-ish is live; FORCE=1 overrides a stale process.
BUSY="$(ssh "$HOST" "ps ax 2>/dev/null | grep -iE 'quake2|quakespasm|q2ded|/quake' | grep -v grep || true")"
if [ -n "$BUSY" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[bench $HOST] ABORT — $HOST is already running a game (shared bench):" >&2
  echo "$BUSY" | sed 's/^/    /' >&2
  echo "[bench $HOST] wait for it to finish, or re-run with FORCE=1 if it is stale." >&2
  exit 2
fi

COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
COMMIT_SUBJECT=$(git -C "$REPO_ROOT" log -1 --format=%s "$COMMIT" 2>/dev/null | tr ',' ';' | head -c 80)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# BENCH_CSV/BENCH_RAW_DIR override the output paths. Both default to the
# git-tracked historical record (benchmarks/results.csv, benchmarks/raw/),
# where every row and log is committed alongside the narrated decision it
# supports (never a bare number, see MISTAKES.md). An automated caller (e.g.
# a Jenkins bench job) that has no human curating a commit per run should
# point BOTH at a gitignored path instead — old-mac-build-host#28 caught
# BENCH_CSV alone still leaving qconsole.log copies in the tracked
# benchmarks/raw/.
RAW_DIR="${BENCH_RAW_DIR:-$REPO_ROOT/benchmarks/raw}"
CSV="${BENCH_CSV:-$REPO_ROOT/benchmarks/results.csv}"
mkdir -p "$RAW_DIR" "$(dirname "$CSV")"

# Per-machine hardware/OS metadata. Hardcoded rather than detected on
# every run because (a) these machines are immutable retro hardware,
# (b) `sw_vers` + `sysctl` over ssh adds 6+ remote-shell round trips
# per bench cell, and (c) hardcoding keeps the CSV reproducible — if
# the same row is re-benched on a different box by accident, the
# hardware column won't lie.
case "$TARGET" in
  yosemite)    META_CPU="PPC 750 @ 449MHz";    META_GPU="ATI Rage 128 16MB";          META_OS="10.3.9 Panther" ;;
  yosemite-tiger) META_CPU="PPC 750 @ 449MHz"; META_GPU="ATI Rage 128 16MB";          META_OS="10.4.11 Tiger" ;;
  sawtooth)    META_CPU="PPC 7400 @ 500MHz";   META_GPU="NVIDIA GeForce2 MX 32MB";    META_OS="10.4.11 Tiger" ;;
  quicksilver) META_CPU="PPC 7450 @ 733MHz";   META_GPU="ATI Radeon 9000 Pro 64MB";   META_OS="10.4.11 Tiger" ;;
  mini-g4)     META_CPU="PPC 7447A @ 1.25GHz"; META_GPU="ATI Radeon 9200 32MB";       META_OS="10.4.11 Tiger" ;;
  imac-g5)     META_CPU="PPC 970FX @ 2.0GHz";  META_GPU="ATI Radeon 9600 128MB";      META_OS="10.5.8 Leopard" ;;
  # PowerMac7,3 (Power Mac G5 Dual, Late 2004/2005), one physical box, three
  # OS partitions -- specs from autoexec-g5-dual.cfg's own header. Issue #61.
  g5-panther)  META_CPU="PPC 970 Dual @ 2.7GHz";META_GPU="ATI Radeon 9600 128MB";     META_OS="10.3.9 Panther" ;;
  g5-tiger)    META_CPU="PPC 970 Dual @ 2.7GHz";META_GPU="ATI Radeon 9600 128MB";     META_OS="10.4.11 Tiger" ;;
  g5-desktop)  META_CPU="PPC 970 Dual @ 2.7GHz";META_GPU="ATI Radeon 9600 128MB";     META_OS="10.5.8 Leopard" ;;
  # Power Mac G5 Quad (PowerMac11,2), one physical box, two OS partitions.
  # GPU confirmed (old-mac-build-host/docs/HOSTS.md: "the Quad's 2004-era
  # NVIDIA GeForce 6600"); CPU is the model's known public spec (4x PPC
  # 970MP @ 2.5GHz) -- NOT independently re-verified via sysctl on this box,
  # both aliases were off/unreachable when this was written.
  quad-tiger)   META_CPU="PPC 970MP x4 @ 2.5GHz"; META_GPU="NVIDIA GeForce 6600";     META_OS="10.4.x Tiger" ;;
  quad-leopard) META_CPU="PPC 970MP x4 @ 2.5GHz"; META_GPU="NVIDIA GeForce 6600";     META_OS="10.5.8 Leopard" ;;
  mini-intel)  META_CPU="Core 2 Duo @ 2.33GHz";META_GPU="Intel GMA 950 64MB";         META_OS="10.7.5 Lion" ;;
  imac-2019)   META_CPU="i5-9600K @ 3.7GHz";   META_GPU="AMD Radeon Pro 580X 8GB";    META_OS="15.7 Sequoia" ;;
esac

# Detect which build flavour is on the host: fat universal binary lives
# inside Quake2.app/Contents/MacOS/; per-target lives in the deploy root.
# Captures the binary's actual Mach-O architectures via `file` so the
# CSV row pins down exactly what was tested.
BUILD_TYPE=$(ssh "$HOST" 'if [ -f ~/quake2-play/Quake2.app/Contents/MacOS/quake2 ]; then
  echo "fat"
elif [ -f ~/quake2-play/quake2 ]; then
  echo "per-target"
else
  echo "unknown"
fi' 2>/dev/null || echo "unknown")

# Notes: caller-supplied free-form context (e.g. NOTES="Phase A baseline").
# Commas are sanitised to semicolons so CSV stays parseable. The commit
# subject is always appended automatically so future-you can read why a
# row exists without having to cross-ref the git log.
# EXTRA goes in the notes, always. Without it an A/B writes two rows that are
# identical in every column a reader can see -- same machine, same demo, same
# resolution, different fps -- and nothing says which leg was which. Measured
# 2026-08-22: a gl_farsee A/B on mini-g4 produced exactly that pair, 40.90 and
# 41.10, indistinguishable in the data. The mode is recorded for the same
# reason: quake3 found six settings free WINDOWED and -9.7% fullscreen, so a
# figure without its mode ranks settings but cannot say where a floor breaks.
BENCH_COND="mode=$([ "$VID_FS" = 1 ] && echo fullscreen || echo windowed)"
[ "${VID_DFS:-0}" = 1 ] && BENCH_COND="mode=desktopfullscreen"
[ -n "${EXTRA:-}" ] && BENCH_COND="$BENCH_COND EXTRA=${EXTRA}"
NOTES_RAW="${NOTES:-Phase A baseline} | $BENCH_COND | $COMMIT_SUBJECT"
NOTES_CSV=$(echo "$NOTES_RAW" | tr ',' ';' | head -c 240)

# CSV header (initialize once). Atomic via bash noclobber (set -C →
# O_CREAT|O_EXCL), so two parallel bench.sh procs racing on a missing
# CSV produce exactly one header row.
( set -C; echo "timestamp,commit,build_type,machine,cpu,gpu,os,demo,res,run1_fps,run2_fps,run3_fps,median_fps,notes" > "$CSV" ) 2>/dev/null || true

# Orphan cleanup. The per-run teardown below already handles the normal path;
# this only fires when the SCRIPT dies (Ctrl-C, a parent shell going away, a
# killed background job) with the engine still up on the target. That orphan
# keeps rendering fullscreen with nobody polling it, and the next thing to touch
# the machine launches on top of it — power-button territory on the Rage 128 and
# the R300. Same TERM-grace-KILL policy as the run loop; costs nothing on a
# normal exit because there is no engine left to find.
bench_cleanup () {
  ssh -o ConnectTimeout=10 "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 3; fi
    killall -KILL quake2 2>/dev/null
    true" 2>/dev/null || true
}
trap bench_cleanup EXIT INT TERM

# Tag the raw log with EXTRA when this is an A/B leg. Without it a same-day
# A/B (different EXTRA, same commit/target/demo/res) silently overwrites the
# earlier leg's raw qconsole.log -- results.csv still records both rows
# correctly since EXTRA is in the notes column, but the raw evidence for
# every leg but the last is gone. Real incident: hit doing a 3-way A/B on
# imac-2019 for #33. Same fix as quakespasm/scripts/bench.sh:260-269.
# Long EXTRA strings blow past the filesystem's 255-byte name limit, so cap
# the readable part and append a hash of the FULL string for uniqueness.
CVAR_TAG=""
if [ -n "${EXTRA:-}" ]; then
  CVAR_SLUG="$(printf '%s' "$EXTRA" | tr -cs 'A-Za-z0-9' '_' | sed 's/^_//; s/_$//')"
  if [ "${#CVAR_SLUG}" -gt 60 ]; then
    CVAR_HASH="$(printf '%s' "$EXTRA" | shasum -a 256 | cut -c1-8)"
    CVAR_SLUG="$(printf '%s' "$CVAR_SLUG" | cut -c1-60)_$CVAR_HASH"
  fi
  CVAR_TAG="_$CVAR_SLUG"
fi

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
  # invoked with CWD = ~/quake2-play/ so basedir=. picks up ref_gl.so
  # and baseq2/ in the parent directory either way.
  ssh "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 2; fi
    killall -KILL quake2 2>/dev/null || true
    sleep 1
    cd ~/quake2-play
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

  LOG_NAME="${COMMIT}_${TARGET}_${DEMO}_${RES}${CVAR_TAG}_run${i}.log"
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
  echo "[bench] FAIL: $NA/${RUNS} run(s) NA on $TARGET $DEMO $RES — see $RAW_DIR/${COMMIT}_${TARGET}_${DEMO}_${RES}${CVAR_TAG}_run*.log" >&2
  exit 1
fi
