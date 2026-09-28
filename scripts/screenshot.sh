#!/usr/bin/env bash
# Capture a bank of in-game Q2 gameplay screenshots from a deployed target.
#
# How it works:
#   1. Stage an autoshot.cfg in baseq2/ that runs `wait` * N, screenshot,
#      `wait` * M, screenshot, ... × 10, then quit. Putting the chain in a
#      cfg file (rather than on the command line) sidesteps Q2's
#      MAX_NUM_ARGVS=50 cap on +tokens (~50 +wait on the cmdline trips
#      "Error: argc > MAX_NUM_ARGVS"). 8 KB cmd_text_buf also caps the cfg
#      at ~1500 wait lines (5 bytes each); we stay well under.
#   2. Launch the engine with `+set timedemo 1 +demomap demo1.dm2`. Timedemo
#      removes the realtime gate in SV_Frame (sv_main.c:403), so the demo
#      plays one frame per Qcommon_Frame iteration regardless of cl_maxfps
#      — letting our `wait` commands map 1:1 to demo frames. Without it,
#      the demo waits ~100ms wall-clock between server frames and our
#      1ms-per-iteration waits drain before the demo has produced any
#      gameplay frames.
#   3. After 50 initial waits (engine boot + demo precache + plaque clear),
#      take a shot, then `wait` * 65 + screenshot × 9 more. demo1.dm2 is
#      ~689 frames in timedemo, so 50 + 9*65 = 635 frames worth of waits
#      keeps shots inside the demo window.
#   4. scp the 10 TGAs back, convert to PNG, drop into docs/screenshots/.
#
# usage: scripts/screenshot.sh <target>
#        DEMO=demo2.dm2 scripts/screenshot.sh <target>   # pick which demo
# output: docs/screenshots/<target>[-<demo>]-NN.png  (NN = 00..09)
#         docs/screenshots/<target>.png      → hero (copy of demo1-04)
#         When DEMO != demo1.dm2 the demo basename is suffixed:
#           docs/screenshots/<target>-demo2-NN.png
#
# Engine prerequisites (cl_main.c + cl_parse.c patches from this commit):
#   - CL_Frame's PrepRefresh fallback also calls CM_LoadMap + RegisterSounds
#     first. Otherwise the protocol-34 demo's `precache` stufftext gets
#     deferred behind our pending waits, the CL_Frame fallback fires
#     PrepRefresh on configstrings without collision data loaded, and
#     CM_InlineModel(*N) errors with "bad number" → ERR_DROP → demo dies.
#   - CL_ParseFrame re-checks the SCR_EndLoadingPlaque condition every
#     valid frame (not just on the ca_connected→ca_active transition).
#     refresh_prepped flips true a frame or more AFTER the transition
#     when the cmd buffer is loaded with waits, and the loading plaque
#     was getting stuck up forever (120-sec timeout dependency).

set -euo pipefail

TARGET="${1:?usage: $0 <target>}"

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
	exec "$_PICK" --run "$TARGET" "screenshot" -- "$0" "$@"
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${DEMO:-demo1.dm2}"
DEMO_BASE="${DEMO%.dm2}"

# Output tag: legacy <target>-NN.png for demo1, <target>-<demo>-NN.png otherwise.
# Keeps existing docs/screenshots/yosemite-04.png style file paths intact for
# the index.html + README references.
if [ "$DEMO_BASE" = "demo1" ]; then
  OUT_TAG="$TARGET"
else
  OUT_TAG="${TARGET}-${DEMO_BASE}"
fi

case "$TARGET" in
  yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|imac-g5|mini-intel|imac-2019| \
  g5-desktop|g5-panther|g5-tiger|quad-leopard|quad-tiger|mini-sl|mini-intel2|qemu-tiger3d) HOST="$TARGET" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# Video mode for the capture session. A non-native fullscreen mode SWITCH
# hard-hangs the whole OS (physical power button only) on an ATI R300-family
# GPU under Tiger/Leopard — confirmed on the iMac G5's Radeon 9600 and
# g5-desktop's RV351 (issue #31), and R300-family GPUs are shared across the
# g5-panther/g5-tiger/g5-desktop partitions (same box) and unconfirmed on
# quad-leopard/quad-tiger. So the SAFE path — native same-mode CAPTURE
# (vid_desktopfullscreen 1), width/height ignored, shots at the panel's
# native res — is the DEFAULT, and the 1024x768 mode-switch is opt-in, only
# for machines with a confirmed non-R300 GPU. Adding a new target to the
# case above does NOT need touching this: it stays on the safe path unless
# added below. See ADR 0008 and ~/Desktop/imac-g5-leopard-port-notes.md.
SS_FS=1; SS_DFS=1; SS_W=1024; SS_H=768
case "$TARGET" in
  yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019)
    # Rage 128, GeForce2 MX, Radeon 9000/9200, Intel GMA950, AMD — none R300.
    SS_DFS=0
    ;;
  qemu-tiger3d)
    # QemuMac's emulated Radeon 9700 IS R300-family, but this is a VM: a hang
    # costs a VM restart, not a physical power-button trip, and the switch
    # path is already proven here — bench.sh launches it directly (no
    # desktopfullscreen) and it plays demo1 1024x768 correctly (5e0efecc).
    # The opposite is what actually broke: the "safe" no-switch native-mode
    # path this case skips captured 10 byte-identical 99-byte black PNGs on
    # this target (old-mac-quake2#96) -- untested/broken, not a real frame.
    SS_DFS=0
    ;;
  *)
    echo "[screenshot $TARGET] native-res same-mode CAPTURE (R300-safe or unconfirmed GPU; shots at native res)"
    ;;
esac

# Where the PNGs land. Defaults to the docs set that README.md and index.html
# link. scripts/check-frames.sh points this at a temp dir so a verification
# capture never touches the committed images. A peer running this port's
# bench through old-mac-build-host's shared evidence pipeline
# (bench-evidence.sh, build-host#135) exports BENCH_OUT_DIR instead, so a
# screenshot pass driven that way lands there rather than in this repo's
# tracked docs/screenshots/ (SHOT_DIR itself still wins when set explicitly).
SHOT_DIR="${SHOT_DIR:-${BENCH_OUT_DIR:+$BENCH_OUT_DIR/screenshots}}"
SHOT_DIR="${SHOT_DIR:-$REPO_ROOT/docs/screenshots}"

# The docs set is ALSO the reference the visual check compares against, so
# regenerating it silently moves the goalposts. check-frames.sh reads its
# reference from git HEAD rather than the working tree, which is why that is
# safe, but a refresh still has to be reviewed like any other change.
if [ "$SHOT_DIR" = "$REPO_ROOT/docs/screenshots" ]; then
  echo "[screenshot] NOTE: replacing docs/screenshots/${OUT_TAG}-*.png in the working"
  echo "  tree. Those are the reference frames scripts/check-frames.sh compares"
  echo "  against once committed. Review the diff before committing them."
fi

mkdir -p "$SHOT_DIR"

# qemu-tiger3d: the in-game `screenshot` command's guest-side glReadPixels
# comes back solid black on this emulated R300 (qemu#7, old-mac-quake2#97) --
# live rendering and bench.sh's timedemo fps are both fine, only the TGA
# readback is broken. buildhost's own fix for the equivalent bench-evidence.sh
# gap (build-host#123) is host-side: `qemu-vm.sh screendump` reads the
# emulated framebuffer straight off QEMU's HMP monitor socket, bypassing the
# guest entirely. That capability is explicitly NOT wired into screenshot.sh
# from buildhost's side ("port's own tree... will mail the five ports once
# useful") -- this is that wiring, this port's own.
#
# This can't reuse the generic autoshot.cfg path below: that stages all 10
# `screenshot` console commands as one continuous in-guest command chain under
# `timedemo 1` (frames advance as fast as the engine can process commands, no
# real-time pacing), whereas `qemu-vm.sh screendump` is triggered from OUTSIDE
# the guest over ssh, so it needs the demo actually paced in real time
# (`timedemo 0` + a capped `cl_maxfps`) to leave a big enough real-world
# window around each marker for the ssh-poll-then-screendump round trip to
# land before playback moves on. vm-frame-check.sh already proved this same
# echo-marker-into-qconsole.log-then-external-screendump primitive works for
# one frame; this is the same idea spread across 10.
#
# HONEST LIMIT, unlike the generic path: capture timing here depends on
# workstation-side ssh/poll latency, not in-guest frame-exact scheduling, so
# these frames do NOT carry check-frames.sh's normal bit-identical-across-runs
# guarantee (its own header comment). Expect some non-zero run-to-run RMSE
# noise specific to this target -- if that turns out to exceed the shared
# 0.04 threshold in practice, this target needs its own threshold or a
# coarser comparison, decided from measured noise, not guessed here.
if [ "$HOST" = qemu-tiger3d ]; then
  echo "[screenshot $TARGET] qemu-tiger3d: host-side qemu-vm.sh screendump capture (qemu#7 workaround)"
  "$(dirname "$_PICK")/shared.sh" gui-precondition.sh "$HOST" || exit 1

  QNUM_SHOTS=10
  QINITIAL_GAP=900  # frames before the FIRST marker (~15s) -- boot + demo
                     # precache + plaque clear settle, same idea as the
                     # generic path's INITIAL_WAITS but measured empirically
                     # for real-time (not timedemo) playback on this VM. The
                     # loading/connect screen renders unthrottled (cl_maxfps
                     # doesn't gate it), so it burns through hundreds of
                     # `wait` frames in well under a second of real time --
                     # 300 still caught shots 00 AND 01 in boot console text
                     # (live-tested 2026-09-28); 900 is the next empirical step.
  QMARKER_GAP=180   # frames between markers at cl_maxfps 60 below (~3s real time)
  QBUFFER_WAITS=3600 # idle frames held after the LAST marker (~60s) -- a
                     # generous safety net only, NOT what actually ends the
                     # run: an in-cfg fixed-frame `quit` races the host-side
                     # screendump for the last marker (its ssh+convert round
                     # trip has no fixed duration), and any value here is a
                     # guess at that race, not a fix for it. 120 then 600
                     # both measured too tight and still came back solid
                     # black some runs. The host now sends its own
                     # killall -TERM once it has confirmed the last
                     # screendump on disk (below); this wait count only
                     # covers the case where that explicit kill is somehow
                     # missed.

  ssh "$HOST" 'mkdir -p ~/.yq2/baseq2; : > ~/.yq2/baseq2/qconsole.log'

  QCFG=$(mktemp)
  trap 'rm -f "$QCFG"' EXIT
  {
    for _ in $(seq 1 $QINITIAL_GAP); do echo wait; done
    echo 'echo VM_SHOT_00'
    n=1
    while [ $n -lt $QNUM_SHOTS ]; do
      for _ in $(seq 1 $QMARKER_GAP); do echo wait; done
      printf 'echo VM_SHOT_%02d\n' "$n"
      n=$((n+1))
    done
    for _ in $(seq 1 $QBUFFER_WAITS); do echo wait; done
    echo quit
  } > "$QCFG"
  scp -q "$QCFG" "$HOST:/Applications/Quake2/baseq2/vmshot.cfg"

  ssh "$HOST" "cd /Applications/Quake2
    killall -TERM quake2 2>/dev/null && sleep 2 || true
    killall -KILL quake2 2>/dev/null || true
    sleep 1
    if [ -x ./Quake2.app/Contents/MacOS/quake2 ]; then
      ENGINE=./Quake2.app/Contents/MacOS/quake2
    else
      ENGINE=./quake2
    fi
    \$ENGINE -nolauncher \\
      +set vid_fullscreen 1 +set vid_desktopfullscreen 0 \\
      +set gl_mode -1 +set gl_customwidth $SS_W +set gl_customheight $SS_H \\
      +set s_initsound 0 +set scr_centertime 0 +set logfile 2 \\
      +set timedemo 0 +set cl_maxfps 60 \\
      ${EXTRA:-} \\
      +demomap $DEMO +exec vmshot.cfg" &
  SESSION_PID=$!

  rm -f "$SHOT_DIR/${OUT_TAG}-"[0-9][0-9].png
  n=0
  while [ $n -lt $QNUM_SHOTS ]; do
    marker=$(printf 'VM_SHOT_%02d' "$n")
    found=0
    for _ in $(seq 1 60); do
      kill -0 "$SESSION_PID" 2>/dev/null || break
      if ssh "$HOST" "grep -q $marker ~/.yq2/baseq2/qconsole.log" 2>/dev/null; then
        found=1; break
      fi
      sleep 1
    done
    if [ "$found" = 1 ]; then
      "$REPO_ROOT/scripts/shared.sh" qemu-vm.sh screendump "$SHOT_DIR/${OUT_TAG}-$(printf '%02d' "$n").png"
    else
      echo "[screenshot $TARGET] WARNING: marker $marker never appeared" >&2
    fi
    n=$((n+1))
  done
  # The last screendump is on disk now (or the marker never appeared and we
  # gave up on it) -- end the run ourselves instead of racing the cfg's own
  # fixed-frame quit against that capture.
  ssh "$HOST" 'killall -TERM quake2 2>/dev/null' || true
  wait "$SESSION_PID" || true
  ssh "$HOST" 'rm -f /Applications/Quake2/baseq2/vmshot.cfg' 2>/dev/null || true

  GOT=$(ls "$SHOT_DIR/${OUT_TAG}-"[0-9][0-9].png 2>/dev/null | wc -l | tr -d ' ')
  if [ "$GOT" -eq 0 ]; then
    echo "[screenshot] no frames captured on $HOST" >&2
    exit 1
  fi
  if [ "$DEMO_BASE" = "demo1" ]; then
    HERO="$SHOT_DIR/${TARGET}-06.png"
    [ -f "$HERO" ] && cp "$HERO" "$SHOT_DIR/${TARGET}.png"
  fi
  echo "[screenshot] OK — $GOT PNGs (qemu-tiger3d host-side capture)"
  ls -la "$SHOT_DIR/${OUT_TAG}"*.png 2>&1 | head -15
  exit 0
fi

# Schedule: 10 shots evenly spread across the first ~635 demo frames of
# demo1.dm2 (which is 689 frames end-to-end). With timedemo 1 each wait
# advances the demo by one frame, so the wait counts double as frame
# offsets.
INITIAL_WAITS=50      # boot + precache + plaque-clear settle
WAITS_BETWEEN=65      # demo frames between shots; 9 × 65 = 585
NUM_SHOTS=10

echo "[screenshot] staging autoshot.cfg on $HOST ($NUM_SHOTS shots)"
STAGE_CFG=$(mktemp)
TMPD=$(mktemp -d)
# Expanded NOW, not at signal time. The variable is assigned on the line above
# and never reassigned, so both spellings behave identically here, and baking
# the literal path in means an rm -rf trap cannot be redirected by a later
# reassignment. Issue #22.
# shellcheck disable=SC2064
trap "rm -rf '$STAGE_CFG' '$TMPD'" EXIT

{
  # First settle window
  for _ in $(seq 1 $INITIAL_WAITS); do echo wait; done
  echo screenshot
  # Shots 2..N spread through demo runtime
  n=2
  while [ $n -le $NUM_SHOTS ]; do
    for _ in $(seq 1 $WAITS_BETWEEN); do echo wait; done
    echo screenshot
    n=$((n+1))
  done
  # Pad and exit cleanly. Two waits give the last TGA write a frame to
  # finish before the engine tears down.
  echo wait
  echo wait
  echo quit
} > "$STAGE_CFG"

LINES=$(wc -l < "$STAGE_CFG" | tr -d ' ')
echo "[screenshot]   cfg size: $LINES lines"

scp -q "$STAGE_CFG" "$HOST:/Applications/Quake2/baseq2/autoshot.cfg"

# A locked or shielded console captures black (old-mac-build-host#88).
"$(dirname "$_PICK")/shared.sh" gui-precondition.sh "$HOST" || exit 1

echo "[screenshot] launch quake2 → timedemo demo1.dm2 → capture series → quit"
# Engine path auto-detect: fat deploys ship Quake2.app/Contents/MacOS/quake2;
# per-target deploys ship a flat ./quake2 next to the binary. Both are
# invoked with CWD = /Applications/Quake2/ so basedir=. picks up ref_gl.so and
# baseq2/ in the parent directory either way.
ssh "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 2; fi
  killall -KILL quake2 2>/dev/null || true
  sleep 1
  cd /Applications/Quake2
  rm -f ~/.yq2/baseq2/scrnshot/quake*.tga
  rm -f ~/.yq2/baseq2/qconsole.log
  if [ -x ./Quake2.app/Contents/MacOS/quake2 ]; then
    ENGINE=./Quake2.app/Contents/MacOS/quake2
  else
    ENGINE=./quake2
  fi
  \$ENGINE -nolauncher \\
    +set vid_fullscreen $SS_FS +set vid_desktopfullscreen $SS_DFS \\
    +set gl_mode -1 +set gl_customwidth $SS_W +set gl_customheight $SS_H \\
    +set s_initsound 0 \\
    +set scr_centertime 0 \\
    +set deathmatch 0 +set coop 0 \\
    +set logfile 2 \\
    +set timedemo 1 \\
    ${EXTRA:-} \\
    +demomap $DEMO +exec autoshot.cfg > /dev/null 2>&1 &
  PID=\$!
  # Wait for engine to produce the last shot, exit, or time out.
  # G3 at ~15 fps × 600 frames = ~40 sec; 180 sec is a safe ceiling.
  j=0
  while [ \$j -lt 180 ]; do
    if [ -f ~/.yq2/baseq2/scrnshot/quake0$((NUM_SHOTS - 1)).tga ]; then break; fi
    if ! kill -0 \$PID 2>/dev/null; then break; fi
    sleep 1; j=\$((j+1))
  done
  sleep 2
  killall -TERM quake2 2>/dev/null
  sleep 2
  killall -KILL quake2 2>/dev/null
  ls ~/.yq2/baseq2/scrnshot/ 2>&1 | head -15"

echo "[screenshot] fetch TGAs"
scp -q "$HOST:.yq2/baseq2/scrnshot/quake0*.tga" "$TMPD/" || true
TGAS=$(ls "$TMPD"/*.tga 2>/dev/null | sort)
if [ -z "$TGAS" ]; then
  echo "[screenshot] no TGAs captured on $HOST" >&2
  exit 1
fi

# Pick the converter once.
CONV=""
if   command -v magick  >/dev/null 2>&1; then CONV="magick"
elif command -v gm      >/dev/null 2>&1; then CONV="gm convert"
elif command -v convert >/dev/null 2>&1; then CONV="convert"
else
  echo "[screenshot] no TGA→PNG converter — leaving .tga in place" >&2
  cp "$TMPD"/*.tga "$SHOT_DIR/"
  exit 0
fi

echo "[screenshot] convert TGAs → PNGs ($CONV)"
# Wipe any prior per-shot files for this OUT_TAG so a shorter run doesn't
# leave stale shots from a previous longer run lying around. Note we wipe
# OUT_TAG specifically — for demo2 runs that won't clobber demo1 shots.
rm -f "$SHOT_DIR/${OUT_TAG}-"[0-9][0-9].png
i=0
for tga in $TGAS; do
  OUT="$SHOT_DIR/${OUT_TAG}-$(printf "%02d" $i).png"
  $CONV "$tga" "$OUT"
  echo "  $OUT"
  i=$((i+1))
done

# Pick a "hero" shot. Frame 04 is during the demo1.dm2 fog-volume
# transition — comes out monochrome cyan/red wash, looked terrible
# in README marketing strips. Frame 06 is reliably mid-corridor with
# a gold door and weapon visible — classic Q2 look, no fog dominance.
# Only do this for the canonical demo1 run, so multi-demo runs don't
# keep overwriting it.
if [ "$DEMO_BASE" = "demo1" ]; then
  HERO="$SHOT_DIR/${TARGET}-06.png"
  if [ -f "$HERO" ]; then
    cp "$HERO" "$SHOT_DIR/${TARGET}.png"
  fi
fi

# Remove the staged autoshot.cfg so it doesn't sit in the user's baseq2/.
ssh "$HOST" 'rm -f /Applications/Quake2/baseq2/autoshot.cfg' 2>/dev/null || true

echo "[screenshot] OK — $(ls "$SHOT_DIR/${OUT_TAG}"-*.png 2>/dev/null | wc -l) PNGs"
ls -la "$SHOT_DIR/${OUT_TAG}"*.png 2>&1 | head -15
