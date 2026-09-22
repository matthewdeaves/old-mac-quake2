#!/usr/bin/env bash
set -euo pipefail
cd /Users/matt/Documents/old-mac-quake2
phase=${1:?shots or bench}
evidence=/private/tmp/q2-scene-resolve-sep22/$phase
mkdir -p "$evidence"
remote=$(ssh mini-sl 'mktemp -d "$HOME/oldmac/quake2/scene-resolve.XXXXXX"')
ssh mini-sl "set -e; test ! -e /Applications/Quake2/baseq2/q2_scene_trial.cfg; cp -p ~/.yq2/baseq2/config.cfg '$remote/config.cfg'; cp -p /Applications/Quake2/ref_gl.so '$remote/original.so'; md5 '$remote/config.cfg' '$remote/original.so'; osascript -e 'set volume 0' -e 'set volume output muted true'" > "$evidence/preflight.txt"
restore() {
 ssh mini-sl "if killall -TERM quake2 2>/dev/null; then sleep 2; fi; killall -KILL quake2 2>/dev/null || true; cp -p '$remote/original.so' /Applications/Quake2/ref_gl.so; cp -p '$remote/config.cfg' ~/.yq2/baseq2/config.cfg; rm -f /Applications/Quake2/baseq2/q2_scene_trial.cfg; md5 /Applications/Quake2/ref_gl.so ~/.yq2/baseq2/config.cfg" > "$evidence/restored-md5.txt"
}
trap restore EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
scp -q /private/tmp/q2-scene.cfg mini-sl:/Applications/Quake2/baseq2/q2_scene_trial.cfg
scp -q /private/tmp/q2-scene-renderer.so mini-sl:/Applications/Quake2/ref_gl.so
ssh mini-sl 'md5 /Applications/Quake2/ref_gl.so' > "$evidence/trial-md5.txt"
cp /private/tmp/q2-scene-SOURCE-STAMP "$evidence/SOURCE-STAMP"
if [ "$phase" = shots ]; then
 for mode in 0 1; do
  EXTRA="+set gl_scene_resolve $mode +exec q2_scene_trial.cfg" SHOT_DIR="$evidence/frames-$mode" scripts/screenshot.sh mini-sl > "$evidence/capture-$mode.log" 2>&1
  scp -q mini-sl:.yq2/baseq2/qconsole.log "$evidence/qconsole-$mode.log"
 done
else
 leg=0
 for demo in demo2 demo1; do
  for mode in 0 1 1 0; do
   leg=$((leg+1))
   EXTRA="+set gl_scene_resolve $mode +exec q2_scene_trial.cfg" NOTES="EXPERIMENT thin scene-resolve renderer plus installed RC2 engine; scene$mode MSAA2 bloom1 projected1 fastrestore1 leg$leg" BENCH_CSV="$evidence/results.csv" BENCH_RAW_DIR="$evidence/raw-$leg" scripts/bench.sh mini-sl "$demo" 1920x1080 3
  done
 done
fi
