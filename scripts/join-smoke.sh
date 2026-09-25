#!/usr/bin/env bash
# Join a live server from the INSTALLED client and stay in the game, as a
# player would. smoke-dmg.sh proves a demo renders; this proves the network
# path: connect, precache, spawn, and remain connected for HOLD seconds.
#
# usage: scripts/join-smoke.sh <machine> <address:port> [player-name]
#
# The address is an argument on purpose. This repo is public and the server
# topology is not ours to publish; it lives on retro-server-infra#27.
#
# Launch is a direct exec from /Applications/Quake2 with the production bundle
# config (no -noarchautoexec, no vid/res override), the same transport bench.sh
# uses, because Panther/Tiger/Leopard's `open` cannot carry +connect. Sound is
# off (s_initsound 0) so a fleet test never touches the user's volume.
#
# Panther and Tiger have no shasum; md5 is what release evidence records anyway.
#
# PASS: this client's own "<name> entered the game" line appears (the server
# broadcasts it on ClientBegin), then the process stays alive for HOLD seconds
# with no disconnect/drop line. Times are stamped on THIS Mac in UTC, since the
# old Macs' clocks are not trusted. The server side confirms it independently.

set -euo pipefail
HOST="${1:?usage: $0 <machine> <address:port> [player-name]}"
ADDR="${2:?usage: $0 <machine> <address:port> [player-name]}"

# Claim the machine for the whole run; see smoke-dmg.sh for why this re-execs.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "join-smoke" -- "$0" "$@"
fi

# Quake II names are at most 15 characters.
NAME="${3:-q2-$HOST}"
NAME="$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9_-' | cut -c1-15)"
HOLD="${JOIN_HOLD:-70}"

# Spawn budget covers engine start, connect, map load and precache.
case "$HOST" in
  yosemite|yosemite-tiger)            SPAWN_TIMEOUT=240; COOLDOWN=5 ;;
  sawtooth|quicksilver|mini-g4)       SPAWN_TIMEOUT=150; COOLDOWN=3 ;;
  imac-g5|g5-desktop|g5-tiger|g5-panther|quad-leopard|quad-tiger)
                                      SPAWN_TIMEOUT=120; COOLDOWN=2 ;;
  mini-intel|mini-intel2|mini-sl)     SPAWN_TIMEOUT=90;  COOLDOWN=1 ;;
  imac-2019|workstation)              SPAWN_TIMEOUT=60;  COOLDOWN=1 ;;
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac
SPAWN_TIMEOUT="${JOIN_SPAWN_TIMEOUT:-$SPAWN_TIMEOUT}"

host_exec () {
  if [ "$HOST" = workstation ]; then /bin/sh -c "$1"; else ssh "$HOST" "$1"; fi
}
host_fetch () {
  if [ "$HOST" = workstation ]; then cp "$HOME/$1" "$2"; else scp -q "$HOST:$1" "$2"; fi
}
utc () { date -u +%Y-%m-%dT%H:%M:%SZ; }

BUSY="$(host_exec 'ps ax -o ucomm= 2>/dev/null | grep -E "^(xash3d|quake2|q2ded|quake3|ioquake3|quakespasm|alephone|Aleph One|Marathon)" || true')"
if [ -n "$BUSY" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "[join $HOST] ABORT — a game is already running there:" >&2
  echo "$BUSY" | sed 's/^/    /' >&2
  exit 2
fi

if [ "$HOST" = workstation ]; then
  "$(dirname "$_PICK")/shared.sh" gui-precondition.sh || exit 1
else
  "$(dirname "$_PICK")/shared.sh" gui-precondition.sh "$HOST" || exit 1
fi

INFO="$(host_exec '
  B=/Applications/Quake2/Quake2.app/Contents/MacOS/quake2
  [ -x "$B" ] || { echo "NO_INSTALL"; exit 0; }
  echo "os=$(sw_vers -productVersion) arch=$(arch) sha256=$(shasum -a 256 "$B" 2>/dev/null | cut -c1-64) md5=$(md5 -q "$B" 2>/dev/null || openssl md5 < "$B" | sed "s/.* //")"
  ')"
case "$INFO" in NO_INSTALL*) echo "[join $HOST] FAIL: no installed Quake2.app" >&2; exit 9 ;; esac
echo "[join $HOST] client: $INFO"
echo "[join $HOST] name=$NAME hold=${HOLD}s spawn-timeout=${SPAWN_TIMEOUT}s"

# The remote loop prints markers; this side stamps them as they arrive.
START_UTC="$(utc)"
echo "[join $HOST] $START_UTC launch"
host_exec "
  if killall -TERM quake2 2>/dev/null; then sleep 2; fi
  killall -KILL quake2 2>/dev/null || true
  sleep 1
  cd /Applications/Quake2 || exit 9
  mv -f ~/.yq2/baseq2/qconsole.log ~/.yq2/baseq2/qconsole.prev.log 2>/dev/null || true
  ./Quake2.app/Contents/MacOS/quake2 -nolauncher +set logfile 2 +set s_initsound 0 \\
    +set name '$NAME' +connect '$ADDR' > /dev/null 2>&1 &
  PID=\$!
  L=~/.yq2/baseq2/qconsole.log
  j=0; spawned=0
  while [ \$j -lt $SPAWN_TIMEOUT ]; do
    if [ -f \$L ] && grep -q '$NAME entered the game' \$L 2>/dev/null; then spawned=1; break; fi
    kill -0 \$PID 2>/dev/null || break
    sleep 1; j=\$((j+1))
  done
  if [ \$spawned = 1 ]; then
    echo MARK_SPAWNED
    k=0
    while [ \$k -lt $HOLD ]; do
      kill -0 \$PID 2>/dev/null || { echo MARK_DIED; break; }
      if grep -qiE 'Server disconnected|was kicked|Connection refused|Server is full|ERROR:' \$L 2>/dev/null; then
        echo MARK_DROPPED; break
      fi
      sleep 1; k=\$((k+1))
    done
    [ \$k -ge $HOLD ] && echo MARK_HELD
  else
    kill -0 \$PID 2>/dev/null && echo MARK_NOSPAWN || echo MARK_DIED
  fi
  killall -TERM quake2 2>/dev/null
  sleep 2
  killall -KILL quake2 2>/dev/null || true
  wait \$PID 2>/dev/null
  sleep $COOLDOWN
  true" 2>&1 | while IFS= read -r line; do
    case "$line" in MARK_*) echo "[join $HOST] $(utc) ${line#MARK_}" ;; esac
  done | tee "${TMPDIR:-/tmp}/join-$HOST.marks"
END_UTC="$(utc)"
echo "[join $HOST] $END_UTC quit"

TMP=$(mktemp)
host_fetch ".yq2/baseq2/qconsole.log" "$TMP" 2>/dev/null || { echo "[join $HOST] FAIL: no qconsole.log" >&2; exit 1; }
if [ -n "${JOIN_LOG_DIR:-}" ]; then mkdir -p "$JOIN_LOG_DIR"; cp "$TMP" "$JOIN_LOG_DIR/join-$HOST.log"; fi
echo "[join $HOST] renderer: $(grep -E 'GL_RENDERER' "$TMP" | tail -1 || true)"
echo "[join $HOST] connect : $(grep -E -m1 '^Connecting to|^connect' "$TMP" | sed "s/$ADDR/<server>/" || true)"
# Precache progress has no newlines, so print the matches, not whole lines.
grep -oE "[A-Za-z0-9_-]+ entered the game|Server disconnected[^.]*|was kicked[^.]*|ERROR:.{0,80}" "$TMP" | sed "s/^/    /" | head -8 || true
MARKS="$(cat "${TMPDIR:-/tmp}/join-$HOST.marks")"; rm -f "$TMP" "${TMPDIR:-/tmp}/join-$HOST.marks"

if printf '%s' "$MARKS" | grep -q HELD; then
  echo "[join $HOST] PASS — spawned and stayed in game ${HOLD}s (window $START_UTC .. $END_UTC)"
  exit 0
fi
echo "[join $HOST] FAIL — $(printf '%s' "$MARKS" | tail -1 | sed 's/.* //')" >&2
exit 1
