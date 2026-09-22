#!/usr/bin/env bash
set -euo pipefail
cd /Users/matt/Documents/old-mac-quake2
evidence=/private/tmp/q2-gpu-passes-sep22
mkdir -p "$evidence"
remote=$(ssh mini-sl 'mktemp -d "$HOME/oldmac/quake2/gpu-passes.XXXXXX"')
ssh mini-sl "set -e; for name in q2_gpu_0.cfg q2_gpu_1.cfg q2_gpu_async.cfg; do test ! -e /Applications/Quake2/baseq2/\$name; done; cp -p ~/.yq2/baseq2/config.cfg '$remote/config.cfg'; cp -p /Applications/Quake2/ref_gl.so '$remote/original.so'; md5 '$remote/config.cfg' '$remote/original.so'; osascript -e 'set volume 0' -e 'set volume output muted true'" > "$evidence/preflight.txt"
restore() {
 ssh mini-sl "if killall -TERM quake2 2>/dev/null; then sleep 2; fi; killall -KILL quake2 2>/dev/null || true; cp -p '$remote/original.so' /Applications/Quake2/ref_gl.so; cp -p '$remote/config.cfg' ~/.yq2/baseq2/config.cfg; rm -f /Applications/Quake2/baseq2/q2_gpu_0.cfg /Applications/Quake2/baseq2/q2_gpu_1.cfg /Applications/Quake2/baseq2/q2_gpu_async.cfg; md5 /Applications/Quake2/ref_gl.so ~/.yq2/baseq2/config.cfg" > "$evidence/restored-md5.txt"
}
trap restore EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
scp -q /private/tmp/q2_gpu_0.cfg /private/tmp/q2_gpu_1.cfg /private/tmp/q2_gpu_async.cfg mini-sl:/Applications/Quake2/baseq2/
scp -q /private/tmp/q2-gpu-diagnostic-renderer.so mini-sl:/Applications/Quake2/ref_gl.so
ssh mini-sl 'md5 /Applications/Quake2/ref_gl.so' > "$evidence/diagnostic-md5.txt"
cp /private/tmp/q2-gpu-diagnostic-SOURCE-STAMP "$evidence/SOURCE-STAMP"
leg=0
for pair in async:2 1:2 0:2 0:0 1:0 1:2; do
 mode=${pair%:*}; aa=${pair#*:}; leg=$((leg+1))
 EXTRA="+set gl_msaa_samples $aa +exec q2_gpu_$mode.cfg" NOTES="INSTRUMENTED PASS PROBE NOT AN FPS BENCHMARK; mode$mode MSAA$aa leg$leg" BENCH_CSV="$evidence/instrumented-not-benchmark.csv" BENCH_RAW_DIR="$evidence/raw-$leg" scripts/bench.sh mini-sl demo2 1920x1080 1
done
EXTRA='+set gl_msaa_samples 2 +exec q2_gpu_1.cfg' SHOT_DIR="$evidence/frames" scripts/screenshot.sh mini-sl > "$evidence/capture.log" 2>&1
