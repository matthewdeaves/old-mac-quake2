#!/usr/bin/env bash
# fault-cell.sh <label> <server> [extra +set args...] : #84. One live-join cell
# on mini-sl, watching kernel.log for NVDA channel faults. Kills the game at the
# FIRST new fault. Must run inside a mini-sl claim (RETRO_BENCH_LOCK=mini-sl).
set -uo pipefail
LABEL="$1"; ADDR="$2"; shift 2; EXTRA="$*"
H=mini-sl; NAME="q2-sl-$LABEL"; NAME="${NAME:0:15}"
[ "${RETRO_BENCH_LOCK:-}" = "$H" ] || { echo "run inside a mini-sl claim" >&2; exit 2; }
utc () { date -u +%H:%M:%S; }
echo "[$LABEL] $(utc) start extra=[$EXTRA]"
ssh "$H" "
  K=/var/log/kernel.log
  fc () { grep -c 'NVDA(OpenGL): Channel \(exception\|timeout\)' \$K; }
  ps ax -o ucomm= | grep -qE '^(quake2|xash3d|quake3|ioquake3|quakespasm)' && { echo GAME_RUNNING; exit 2; }
  F0=\$(fc); echo \"faults_before=\$F0\"
  cd '${Q2DIR:-/Applications/Quake2}' || exit 9; echo \"engine md5: \$(md5 -q Quake2.app/Contents/MacOS/quake2)\"
  mv -f ~/.yq2/baseq2/qconsole.log ~/.yq2/baseq2/qconsole.prev.log 2>/dev/null
  ./Quake2.app/Contents/MacOS/quake2 -nolauncher +set logfile 2 +set s_initsound 0 $EXTRA \
    +gl_bloom +gl_msaa_samples +gl_stencilshadow +gl_mode \
    +set name '$NAME' +connect '$ADDR' >/dev/null 2>&1 &
  P=\$!; t=0; spawn=-1; res=TIMEOUT
  while [ \$t -lt 160 ]; do
    F=\$(fc)
    if [ \$F -gt \$F0 ]; then res=\"FAULT at t=\${t}s (+\$((F-F0)))\"; break; fi
    kill -0 \$P 2>/dev/null || { res=\"DIED at t=\${t}s\"; break; }
    if [ \$spawn -lt 0 ] && grep -q '$NAME entered the game' ~/.yq2/baseq2/qconsole.log 2>/dev/null; then spawn=\$t; fi
    if [ \$spawn -ge 0 ] && [ \$((t-spawn)) -ge 70 ]; then res=\"CLEAN (spawned t=\${spawn}s, held 70s)\"; break; fi
    sleep 1; t=\$((t+1))
  done
  killall -TERM quake2 2>/dev/null; sleep 3; killall -KILL quake2 2>/dev/null
  sleep 2; F1=\$(fc)
  echo \"result: \$res\"; echo \"faults_after_quit=\$F1 (delta \$((F1-F0)))\"
  grep -E '^\"(gl_bloom|gl_msaa_samples|gl_stencilshadow|gl_mode)\" is' ~/.yq2/baseq2/qconsole.log | tr '\n' ' '; echo
  grep -h 'NVDA(OpenGL)' \$K | tail -\$((F1-F0 > 3 ? 3 : F1-F0)) | cut -c1-140
" 2>&1 | sed "s/^/[$LABEL] /"
echo "[$LABEL] $(utc) end"
