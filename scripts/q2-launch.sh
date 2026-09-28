# shellcheck shell=bash
# q2-launch.sh - source me. The one way this repo starts the engine on a fleet
# host: through the shared launch-game.sh (build-host#147, our #108), which
# refuses while ANY game is already running there, arms a guest-side watchdog,
# and stops with TERM first.
#
#   q2_launch HOST MAX_SECS ENGINE_ARG...   sets Q2_PID; returns 3 if refused
#   q2_stop   HOST                          TERM Q2_PID (then KILL, ADR 0009, not on G5s); 1 if it survived
#   q2_pretidy HOST                         TERM a stale quake2 of ours (no KILL)
#
# Engine path: fat deploys ship Quake2.app/Contents/MacOS/quake2, per-target
# deploys a flat ./quake2; both run with CWD=/Applications/Quake2 so basedir=.
# finds ref_gl.so and baseq2/. launch-game.sh (shared-v25) execs `sh -c` in the
# remote shell whose pid it reports, and the script ends in `exec $E`, so that
# pid stays the engine's.
_Q2L_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q2_PID=""

q2_launch () {
  local host="$1" max="$2"; shift 2
  local body a out rc
  body='cd /Applications/Quake2 && if [ -x ./Quake2.app/Contents/MacOS/quake2 ]; then E=./Quake2.app/Contents/MacOS/quake2; else E=./quake2; fi; exec $E'
  for a in "$@"; do body="$body $(printf '%q' "$a")"; done
  rc=0
  out="$("$_Q2L_DIR/shared.sh" launch-game.sh "$host" quake2 --max-secs "$max" -- sh -c "$body")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  Q2_PID="${out##*PID }"
  case "$Q2_PID" in ''|*[!0-9]*) Q2_PID=""; echo "q2_launch: no pid in '$out'" >&2; return 1 ;; esac
}

q2_stop () {
  local host="$1" pid="$Q2_PID" cmd
  [ -n "$pid" ] || return 0
  "$_Q2L_DIR/shared.sh" launch-game.sh --stop "$host" "$pid" >/dev/null 2>&1 && { Q2_PID=""; return 0; }
  # TERM did not end it. ADR 0009: a finished timedemo (or an ERR_DROP) leaves
  # the engine redrawing the console forever, and it ignores SIGTERM there
  # (seen on mini-g4 and qemu-tiger3d, 2026-09-28). Our policy is TERM, grace,
  # then KILL, except on the G5 tower/iMac aliases whose Radeon 9600/R300
  # Leopard driver hangs the whole OS on a hard kill.
  case "$host" in
    imac-g5|g5-*|quad-*) echo "q2_stop: pid $pid ignored TERM on $host; NOT sending KILL (G5 driver hazard), quit it by hand" >&2; return 1 ;;
  esac
  cmd="kill -KILL $pid 2>/dev/null; sleep 2; ! kill -0 $pid 2>/dev/null"
  if [ "$host" = workstation ]; then /bin/sh -c "$cmd"; else ssh -o ConnectTimeout=8 "$host" "$cmd"; fi || return 1
  Q2_PID=""
}

q2_pretidy () {
  local host="$1" cmd='if killall -TERM quake2 2>/dev/null; then sleep 3; fi; true'
  if [ "$host" = workstation ]; then /bin/sh -c "$cmd"; else ssh "$host" "$cmd"; fi
}
