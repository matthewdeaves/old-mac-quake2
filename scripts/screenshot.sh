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
  yosemite|sawtooth|quicksilver|mini-g4|imac-g5|mini-intel|imac-2019) HOST="$TARGET" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# Video mode for the capture session. All boxes default to a 1024x768
# mode-switch fullscreen for consistent shot dimensions — EXCEPT the iMac
# G5, whose ATI R300 / Leopard driver hard-hangs the whole OS on a
# non-native mode switch (needs the physical power button). On the G5 we
# force the native same-mode CAPTURE (vid_desktopfullscreen 1); width/height
# are then ignored and shots come out at the panel's native res.
# See ~/Desktop/imac-g5-leopard-port-notes.md.
SS_FS=1; SS_DFS=0; SS_W=1024; SS_H=768
if [ "$TARGET" = "imac-g5" ]; then
  SS_DFS=1
  echo "[screenshot imac-g5] native-res same-mode CAPTURE (R300-safe; shots at native res)"
fi

mkdir -p "$REPO_ROOT/docs/screenshots"

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

scp -q "$STAGE_CFG" "$HOST:Desktop/quake2/baseq2/autoshot.cfg"

echo "[screenshot] launch quake2 → timedemo demo1.dm2 → capture series → quit"
# Engine path auto-detect: fat deploys ship Quake2.app/Contents/MacOS/quake2;
# per-target deploys ship a flat ./quake2 next to the binary. Both are
# invoked with CWD = ~/Desktop/quake2/ so basedir=. picks up ref_gl.so and
# baseq2/ in the parent directory either way.
ssh "$HOST" "if killall -TERM quake2 2>/dev/null; then sleep 2; fi
  killall -KILL quake2 2>/dev/null || true
  sleep 1
  cd ~/Desktop/quake2
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
  cp "$TMPD"/*.tga "$REPO_ROOT/docs/screenshots/"
  exit 0
fi

echo "[screenshot] convert TGAs → PNGs ($CONV)"
# Wipe any prior per-shot files for this OUT_TAG so a shorter run doesn't
# leave stale shots from a previous longer run lying around. Note we wipe
# OUT_TAG specifically — for demo2 runs that won't clobber demo1 shots.
rm -f "$REPO_ROOT/docs/screenshots/${OUT_TAG}-"*.png
i=0
for tga in $TGAS; do
  OUT="$REPO_ROOT/docs/screenshots/${OUT_TAG}-$(printf "%02d" $i).png"
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
  HERO="$REPO_ROOT/docs/screenshots/${TARGET}-06.png"
  if [ -f "$HERO" ]; then
    cp "$HERO" "$REPO_ROOT/docs/screenshots/${TARGET}.png"
  fi
fi

# Remove the staged autoshot.cfg so it doesn't sit in the user's baseq2/.
ssh "$HOST" 'rm -f ~/Desktop/quake2/baseq2/autoshot.cfg' 2>/dev/null || true

echo "[screenshot] OK — $(ls "$REPO_ROOT/docs/screenshots/${OUT_TAG}"-*.png 2>/dev/null | wc -l) PNGs"
ls -la "$REPO_ROOT/docs/screenshots/${OUT_TAG}"*.png 2>&1 | head -15
