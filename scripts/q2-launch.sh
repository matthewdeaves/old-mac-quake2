# q2-launch.sh - source me. The one way this repo starts the engine on a fleet
# host: through the shared launch-game.sh (build-host#147, our #108), which
# refuses while ANY game is already running there, arms a guest-side watchdog,
# and stops with TERM only (never KILL: docs/adr/0009 in build-host).
#
#   q2_launch HOST MAX_SECS ENGINE_ARG...   sets Q2_PID; returns 3 if refused
#   q2_stop   HOST                          TERM Q2_PID, clear it; 1 if it survived
#   q2_pretidy HOST                         TERM a stale quake2 of ours (no KILL)
#
# Engine path: fat deploys ship Quake2.app/Contents/MacOS/quake2, per-target
# deploys a flat ./quake2; both run with CWD=/Applications/Quake2 so basedir=.
# finds ref_gl.so and baseq2/. The leading `exec` keeps the pid launch-game.sh
# reports equal to the engine's pid (old /bin/sh does not exec a lone -c command).
_Q2L_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q2_PID=""

q2_launch () {
  local host="$1" max="$2"; shift 2
  local body a out rc
  body='cd /Applications/Quake2 && if [ -x ./Quake2.app/Contents/MacOS/quake2 ]; then E=./Quake2.app/Contents/MacOS/quake2; else E=./quake2; fi; exec $E'
  for a in "$@"; do body="$body $(printf '%q' "$a")"; done
  rc=0
  out="$("$_Q2L_DIR/shared.sh" launch-game.sh "$host" quake2 --max-secs "$max" -- exec sh -c "$body")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  Q2_PID="${out##*PID }"
  case "$Q2_PID" in ''|*[!0-9]*) Q2_PID=""; echo "q2_launch: no pid in '$out'" >&2; return 1 ;; esac
}

q2_stop () {
  local host="$1" pid="$Q2_PID"
  [ -n "$pid" ] || return 0
  "$_Q2L_DIR/shared.sh" launch-game.sh --stop "$host" "$pid" >/dev/null || return 1
  Q2_PID=""
}

q2_pretidy () {
  local host="$1" cmd='if killall -TERM quake2 2>/dev/null; then sleep 3; fi; true'
  if [ "$host" = workstation ]; then /bin/sh -c "$cmd"; else ssh "$host" "$cmd"; fi
}
