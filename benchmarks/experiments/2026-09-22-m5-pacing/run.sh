#!/bin/bash
set -eu
root=/private/tmp/q2-m5-pacing.2FR1Dc
label=${1:?}
sound=${2:-1}
sync=${3:-1}
cp /Users/matt/.yq2/baseq2/config.cfg "$root/config-$label.before"
cleanup() {
 if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; sleep 2; fi
 if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; fi
 cp /Users/matt/.yq2/baseq2/qconsole.log "$root/console-$label.log"
 cp "$root/config-$label.before" /Users/matt/.yq2/baseq2/config.cfg
}
cd /Applications/Quake2
scene=(+demomap demo1.dm2)
if [ "${Q2_GAMEPLAY:-0}" = 1 ]; then scene=(+exec q2_m5_pacing_20260922.cfg); fi
DYLD_INSERT_LIBRARIES="$root/trace.dylib${Q2_TEST_PATCH:+:$root/window-test.dylib}" Q2_TRACE_PATH="$root/$label.csv" ./Quake2.app/Contents/MacOS/quake2 -nolauncher +set s_initsound "$sound" +set s_volume 0.7 +set viewsize 100 +set timedemo 0 +set gl_swapinterval "$sync" "${scene[@]}" >"$root/stdout-$label.log" 2>&1 &
pid=$!
trap cleanup EXIT
sleep 8
if [ "${Q2_NO_SAMPLE:-0}" != 1 ]; then
 /usr/bin/sample "$pid" 6 2 -file "$root/sample-$label.txt" >/dev/null 2>&1 || true
fi
sleep 20
