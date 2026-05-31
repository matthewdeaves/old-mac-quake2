#!/usr/bin/env bash
# Smoke-test the installed copy of the game on a target Mac EXACTLY as a human
# would launch it: the production bundle config (per-arch baseline + per-machine
# overlay) drives the renderer — fullscreen, the machine's own resolution, full
# visual tune. We do NOT pass -noarchautoexec and do NOT override vid/res (that
# is what bench.sh does for deterministic measurement). The only thing we add is
# a timedemo so the run AUTO-EXITS instead of sitting fullscreen forever — proof
# the world actually rendered (an fps line) on the real production path.
#
# This is the gate the corrupt-DMG bug slipped past: deploy+bench was clean, but
# the human DMG-launch path crashed. So we test the as-installed, as-launched
# artifact. See MISTAKES.md + memory/smoke-test-method.md.
#
# usage: scripts/smoke-dmg.sh <machine> [demo]
#   machine: yosemite | mini-g4 | imac-g5 | mini-intel | imac-2019
#   demo:    demo1 (default) | demo2
#
# After this passes, the human starts a NEW GAME by hand — the timedemo proves
# world render + correct res but NOT the live-server/entity spawn path (the G3
# R_MarkLeaves / R300 map-load class of bug only shows there). See CLAUDE.md.

set -euo pipefail
HOST="${1:?usage: $0 <machine> [demo]}"
DEMO="${2:-demo1}"

case "$HOST" in
  yosemite)    TIMEOUT=300; COOLDOWN=5 ;;
  sawtooth)    TIMEOUT=180; COOLDOWN=3 ;;
  quicksilver) TIMEOUT=120; COOLDOWN=2 ;;
  mini-g4)     TIMEOUT=120; COOLDOWN=2 ;;
  imac-g5)     TIMEOUT=90;  COOLDOWN=2 ;;
  mini-intel)  TIMEOUT=60;  COOLDOWN=1 ;;
  imac-2019)   TIMEOUT=45;  COOLDOWN=1 ;;
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac

# The bench fleet is SHARED — multiple Claude agents (this Q2 port + the
# QuakeSpasm Q1 sister project) drive the same Macs. Launching a second
# fullscreen game on a box already running one wedges both. Bail if anything
# Quake-ish is live; FORCE=1 overrides a stale process.
BUSY="$(ssh "$HOST" "ps -axo comm,pid 2>/dev/null | grep -iE 'quake2|quakespasm|q2ded|/quake' | grep -v grep || true")"
if [ -n "$BUSY" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[smoke $HOST] ABORT — $HOST is already running a game (shared bench):" >&2
  echo "$BUSY" | sed 's/^/    /' >&2
  echo "[smoke $HOST] wait for it to finish, or re-run with FORCE=1 if it is stale." >&2
  exit 2
fi

echo "[smoke $HOST] launching installed Quake2.app with PRODUCTION config (as a human would), demo=$DEMO"
# NB: production launch — no -noarchautoexec, no vid/res override. +set timedemo
# is an early command; +demomap is a late command (runs after the bundle config
# + CL_Init), so the demo plays in the machine's production fullscreen mode.
# TERM-before-KILL always: SIGTERM lets SDL restore the captured display — a
# hard KILL black-screens the R300/Leopard G5 (see memory/smoke-test-method.md).
ssh "$HOST" "
  if killall -TERM quake2 2>/dev/null; then sleep 2; fi
  killall -KILL quake2 2>/dev/null || true
  sleep 1
  cd ~/Desktop/quake2 || { echo 'NO_INSTALL'; exit 9; }
  rm -f ~/.yq2/baseq2/qconsole.log
  ./Quake2.app/Contents/MacOS/quake2 -nolauncher \\
    +set logfile 2 +set timedemo 1 +demomap $DEMO.dm2 > /dev/null 2>&1 &
  PID=\$!
  j=0
  while [ \$j -lt $TIMEOUT ]; do
    if [ -f ~/.yq2/baseq2/qconsole.log ] && \\
       grep -q 'frames.*seconds.*fps' ~/.yq2/baseq2/qconsole.log 2>/dev/null; then break; fi
    # bail early if the process died without producing an fps line (a crash)
    if ! kill -0 \$PID 2>/dev/null; then break; fi
    sleep 1; j=\$((j+1))
  done
  killall -TERM quake2 2>/dev/null
  sleep 2
  killall -KILL quake2 2>/dev/null || true
  wait \$PID 2>/dev/null
  sleep $COOLDOWN
  true"

# Pull the log and report.
TMP=$(mktemp)
scp -q "$HOST:.yq2/baseq2/qconsole.log" "$TMP" 2>/dev/null || { echo "[smoke $HOST] FAIL: no qconsole.log (engine never wrote one)"; rm -f "$TMP"; exit 1; }

FPS_LINE=$(grep -E 'frames.*seconds.*fps' "$TMP" 2>/dev/null | tail -1 || true)
MODE_LINE=$(grep -E 'setting mode' "$TMP" 2>/dev/null | tail -1 || true)
DESKTOP_LINE=$(grep -E 'Desktop is' "$TMP" 2>/dev/null | tail -1 || true)
REND_LINE=$(grep -E 'GL_RENDERER' "$TMP" 2>/dev/null | tail -1 || true)
rm -f "$TMP"

echo "[smoke $HOST] renderer : ${REND_LINE:-<none>}"
echo "[smoke $HOST] mode     : ${MODE_LINE:-<none>}"
echo "[smoke $HOST] desktop  : ${DESKTOP_LINE:-<none>}"
echo "[smoke $HOST] result   : ${FPS_LINE:-<NO FPS LINE>}"

if [ -n "$FPS_LINE" ]; then
  echo "[smoke $HOST] PASS — world rendered to completion on the production path"
  exit 0
else
  echo "[smoke $HOST] FAIL — no fps line; the production launch did not render a demo (crash or hang)" >&2
  exit 1
fi
