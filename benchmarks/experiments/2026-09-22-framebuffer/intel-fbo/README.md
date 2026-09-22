# Offscreen bloom workspace experiment

GeForce 9400, Snow Leopard, native 1920x1080 fullscreen, requested MSAA2,
bloom on, darken4, size256 and partial restoration enabled. Each comparison
uses A/B/B/A, three timedemo runs per leg, through `scripts/bench.sh`.
The CSV's median field is the mean of warm runs 2 and 3.

## Measured results

| Workspace | Demo | Window A | Offscreen B | Offscreen B | Window A |
| --- | --- | --- | --- | --- | --- |
| Single-sample renderbuffer, existing copies | demo2 | 48.30 | 48.85 | 48.65 | 48.20 |
| Direct texture ping-pong | demo2 | 47.40 | 50.15 | 49.30 | 48.75 |
| Direct texture ping-pong | demo1 | 50.25 | 50.65 | 50.90 | 49.95 |

The copy variant saves little. The direct variant helps demo2 modestly, but
the baseline also moves between legs. In demo1 the mean of the two warm leg
results rises from 50.10 to 50.775 fps, only 0.675 fps. This is a small measured
benefit, not proof of no effect. Decision: do not ship the additional FBO paths
for this return. All source and test changes were reverted; the existing
partial-restore optimization and graphics defaults remain unchanged. Revisit
only with a different hypothesis targeting the full-resolution work, not another
repeat of these small-workspace variants.

## Artifacts and visual checks

These are temporary thin Lion renderer swaps beside the unchanged installed
engine, not fat-app or DMG acceptance. CSV checkout labels and `fat` build-type
labels do not identify the experimental renderer. Source stamps, patches and
candidate hashes identify it. Original and restored renderer hashes match.
The G3 was not accessed; its cross-build ran on the Intel build host.

`copy/prototype.patch` is the first implementation. `direct-demo2/prototype.patch`
adds texture ping-pong. The latter also ran for demo1. The separate
`hardened-unbenched.patch` isolates optional texture storage from the legacy
fallback and prevents repeated allocation attempts after a mode2 failure.
That revision passed local ASan/UBSan tests and a Lion build but was not the
hardware-timed renderer. Its source stamp and analysis log are separate.
The G3 cross-build log belongs to the earlier direct prototype.

Both variants report zero GL errors for the captured bloom passes. Inspected
frame03 captures show intact scene geometry, textures and bloom. Frame comparisons
exclude the top 80 notification rows and retain the remaining 1920x1000 pixels.
The direct variant's maximum normalized RMSE across ten pairs is 2.06685e-05;
the copy variant's is 2.06038e-05. These are not bit-identical images. Per-frame
values and selected full-size image pairs are retained. Capture timing is not
benchmark timing.

Both system mute commands were sent. This host reports missing audio settings,
so do not claim a successful mute readback. Capture configs explicitly use
volume0 and the benchmark disables sound initialization. Normal renderer and
player config are restored by the experiment's EXIT trap.

Local static analysis reported no cppcheck finding and the existing shadowed
`intensity` parameter warning from clang. Passing these checks does not prove
legacy-driver correctness.
