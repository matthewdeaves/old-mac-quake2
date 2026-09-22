# Framebuffer work reduction, 2026-09-22

Code: `dff140f3`. These are renderer-swap experiments, not final-DMG tests.
The engine remained the deployed `3f6cf8b9` artifact throughout. CSV commit
labels describe the experiment checkout, not the temporary renderer's source
commit. Each directory includes the original, candidate and restored renderer
MD5 records; original and restored hashes match. The engine MD5 was
`d23e8c27b2f172d6dde7d250a91415da` and original renderer MD5 was
`2e5ad14fa52e8c9959a54bbaea774eca`.

All timing legs used the existing `scripts/bench.sh`, vsync off and three
runs. The CSV's `median_fps` field is the mean of warm runs 2 and 3. System
audio was muted; the benchmark also disables engine sound initialization.
Screenshot timing is not benchmark timing.

## Radeon 9200, Tiger, 1024x768

MSAA2, projected stencil shadows, dynamic lights and existing visual settings
were retained. `gl_staticworld 1`, indexed models and lightmap cache were
already archived in this installation. Separate versus combined depth/stencil
clear, demo1 interleaved A/B/B/A warm results:

| Separate | Combined | Combined | Separate |
| --- | --- | --- | --- |
| 40.60 | 55.70 | 55.70 | 40.60 |

Demo2 confirmed 40.40 versus 55.60 fps. The improvement is about 37% without
removing effects. Ten captured frame pairs match in the scene/HUD after
excluding the top 40 rows containing screenshot notification text. A full
matching frame pair is retained in `frames/`.

## GeForce 9400, Snow Leopard, native 1920x1080

MSAA2 and bloom were enabled in both modes. Full-scene versus workspace-only
restoration, demo1 A/B/B/A warm results:

| Full | Partial | Partial | Full |
| --- | --- | --- | --- |
| 42.65 | 49.95 | 49.80 | 42.70 |

Demo2 confirmed 42.00 versus 48.65 fps. This is about 17% faster for the same
bloom settings. Captures are not bit-identical: the retained frame pair has
normalized RMSE 0.0000281262, consistent with small sampling differences.
Startup bloom diagnostics report no GL errors for the measured passes.

Bloom-off was separately measured at 83.80 fps. Enabling optimized bloom
therefore spends frame rate on visual quality; it is not a speed gain over
the old bloom-off profile. Unmeasured GPUs retain bloom-off auto-defaults.

## Regression checks

`bash tests/test-renderer-refactor.sh` passes under ASan/UBSan. New tests
record the production clear calls across all 64 boolean state combinations
and both z-trick phases, and verify bloom workspace coordinates plus unchanged
reduced/offset-view restoration. These tests supplement, not replace, the
hardware image comparisons.

The full source analysis pass was also run with `scripts/analyze.sh`.
Its warnings are investigation leads, not evidence of a performance win.
Final fat-app and DMG validation remains a separate gate.
