#!/usr/bin/env bash
set -euo pipefail
cd /Users/matt/Documents/old-mac-quake2
evidence=/private/tmp/q2-gpu-cost-controlled-sep22
mkdir -p "$evidence"
remote=$(ssh mini-sl 'mktemp -d "$HOME/oldmac/quake2/gpu-cost.XXXXXX"')
ssh mini-sl "cp -p ~/.yq2/baseq2/config.cfg '$remote/config.cfg'; md5 '$remote/config.cfg' /Applications/Quake2/ref_gl.so /Applications/Quake2/Quake2.app/Contents/MacOS/quake2; osascript -e 'set volume 0' -e 'set volume output muted true'" > "$evidence/preflight.txt"
restore() {
 ssh mini-sl "if killall -TERM quake2 2>/dev/null; then sleep 2; fi; killall -KILL quake2 2>/dev/null || true; cp -p '$remote/config.cfg' ~/.yq2/baseq2/config.cfg; rm -f /Applications/Quake2/baseq2/q2_cost_0.cfg /Applications/Quake2/baseq2/q2_cost_1.cfg; md5 ~/.yq2/baseq2/config.cfg /Applications/Quake2/ref_gl.so" > "$evidence/restored-md5.txt"
}
trap restore EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
ssh mini-sl 'test ! -e /Applications/Quake2/baseq2/q2_cost_0.cfg && test ! -e /Applications/Quake2/baseq2/q2_cost_1.cfg'
scp -q /private/tmp/q2_cost_0.cfg /private/tmp/q2_cost_1.cfg mini-sl:/Applications/Quake2/baseq2/
leg=0
for pair in 1:2 0:2 0:0 1:0 1:2; do
 bloom=${pair%:*}; aa=${pair#*:}; leg=$((leg+1))
 EXTRA="+set gl_msaa_samples $aa +exec q2_cost_$bloom.cfg" NOTES="DIAGNOSTIC feature-cost sweep; installed RC2; projected shadows and fastrestore1 explicit; bloom$bloom requestedMSAA$aa leg$leg; no new defaults" BENCH_CSV="$evidence/results.csv" BENCH_RAW_DIR="$evidence/raw-$leg" scripts/bench.sh mini-sl demo2 1920x1080 3
done
