#!/bin/bash
# Runs ON mini-sl under the caller's picker claim. #70: toggle gl_bloom 0 -> 1
# mid-session on the installed app with its production config.
cd /Applications/Quake2 || exit 2
osascript -e 'set volume 0' || exit 8
if killall -TERM quake2 2>/dev/null; then sleep 2; fi
killall -KILL quake2 2>/dev/null || true
{
  i=0; while [ $i -lt 250 ]; do echo wait; i=$((i+1)); done
  echo screenshot
  echo "set gl_bloom 1"
  i=0; while [ $i -lt 120 ]; do echo wait; i=$((i+1)); done
  echo screenshot
  echo wait; echo wait; echo quit
} > baseq2/autoshot.cfg
rm -f ~/.yq2/baseq2/scrnshot/quake*.tga ~/.yq2/baseq2/qconsole.log
./Quake2.app/Contents/MacOS/quake2 -nolauncher +set s_initsound 0 +set s_volume 0 \
  +set logfile 2 +set gl_bloom 0 +set timedemo 1 +demomap demo1.dm2 +exec autoshot.cfg > /dev/null 2>&1 &
PID=$!
j=0; exited=no
while [ $j -lt 150 ]; do
  if ! kill -0 $PID 2>/dev/null; then exited=yes; break; fi
  sleep 1; j=$((j+1))
done
if [ "$exited" = no ]; then kill -TERM $PID 2>/dev/null; sleep 5; kill -KILL $PID 2>/dev/null; fi
rm -f baseq2/autoshot.cfg
echo "EXITED_BY_ITSELF=$exited after ${j}s"
ls ~/.yq2/baseq2/scrnshot/ 2>/dev/null
grep -E "Bloom GL diagnostics|GL_RENDERER|setting mode|Error|error" ~/.yq2/baseq2/qconsole.log | head -8
grep -o 'gl_bloom "[0-9]"' ~/.yq2/baseq2/config.cfg
