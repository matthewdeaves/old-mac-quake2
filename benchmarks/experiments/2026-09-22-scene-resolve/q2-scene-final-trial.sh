#!/usr/bin/env bash
set -euo pipefail
cd /Users/matt/Documents/old-mac-quake2
evidence=/private/tmp/q2-scene-resolve-sep22/final
mkdir -p "$evidence"
remote=$(ssh mini-sl 'mktemp -d "$HOME/oldmac/quake2/scene-final.XXXXXX"')
ssh mini-sl "set -e; test ! -e /Applications/Quake2/baseq2/q2_scene_trial.cfg; cp -p ~/.yq2/baseq2/config.cfg '$remote/config.cfg'; cp -p /Applications/Quake2/ref_gl.so '$remote/original.so'; md5 '$remote/config.cfg' '$remote/original.so'; osascript -e 'set volume 0' -e 'set volume output muted true'" > "$evidence/preflight.txt"
restore() {
 ssh mini-sl "if killall -TERM quake2 2>/dev/null; then sleep 2; fi; killall -KILL quake2 2>/dev/null || true; cp -p '$remote/original.so' /Applications/Quake2/ref_gl.so; cp -p '$remote/config.cfg' ~/.yq2/baseq2/config.cfg; rm -f /Applications/Quake2/baseq2/q2_scene_trial.cfg; md5 /Applications/Quake2/ref_gl.so ~/.yq2/baseq2/config.cfg" > "$evidence/restored-md5.txt"
}
trap restore EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
scp -q /private/tmp/q2-scene.cfg mini-sl:/Applications/Quake2/baseq2/q2_scene_trial.cfg
scp -q /private/tmp/q2-scene-final-renderer.so mini-sl:/Applications/Quake2/ref_gl.so
ssh mini-sl 'md5 /Applications/Quake2/ref_gl.so' > "$evidence/trial-md5.txt"
cp /private/tmp/q2-scene-final-SOURCE-STAMP "$evidence/SOURCE-STAMP"
for mode in 0 1; do
 EXTRA="+set gl_scene_resolve $mode +exec q2_scene_trial.cfg" NOTES="Final six-slice renderer with installed RC2 engine; scene$mode; MSAA2 bloom1 projected1 fastrestore1" BENCH_CSV="$evidence/results.csv" BENCH_RAW_DIR="$evidence/raw-$mode" scripts/bench.sh mini-sl demo2 1920x1080 3
done
SCENE_SHOT_WAITS=51 EXTRA='+set gl_scene_resolve 1 +exec q2_scene_trial.cfg' SHOT_DIR="$evidence/frames-full" bash /private/tmp/q2-scene-screenshot.sh mini-sl > "$evidence/capture-full.log" 2>&1
scp -q mini-sl:.yq2/baseq2/qconsole.log "$evidence/qconsole-full.log"
scp -q /private/tmp/q2-scene-reduced.cfg mini-sl:/Applications/Quake2/baseq2/q2_scene_trial.cfg
SCENE_SHOT_WAITS=51 EXTRA='+set gl_scene_resolve 1 +exec q2_scene_trial.cfg' SHOT_DIR="$evidence/frames-reduced" bash /private/tmp/q2-scene-screenshot.sh mini-sl > "$evidence/capture-reduced.log" 2>&1
scp -q mini-sl:.yq2/baseq2/qconsole.log "$evidence/qconsole-reduced.log"
scp -q /private/tmp/q2-scene-nobloom.cfg mini-sl:/Applications/Quake2/baseq2/q2_scene_trial.cfg
EXTRA='+set gl_scene_resolve 1 +exec q2_scene_trial.cfg' NOTES='CORRECTNESS ONLY: scene-resolve bloom-off fallback' BENCH_CSV="$evidence/fallback-only.csv" BENCH_RAW_DIR="$evidence/raw-nobloom" scripts/bench.sh mini-sl demo1 1920x1080 1
