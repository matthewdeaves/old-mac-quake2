# PPC refactor comparison — 2026-09-08

Internal candidate; no release authorized. Source stamp
`447739046bce38aa86b03e703a33a09612453d631e24e4332f40b97b45d9c7a1`.
Renderer MD5 verified on all three targets:
`4fcfeb0d8e4cce0b514e1d7fda1b9401`.

Same candidate binary in both legs, demo1, fullscreen, bloom disabled,
otherwise machine profiles unchanged. Before sets gl_staticworld,
gl_indexedmodels and gl_lightmap_cache to 0; after sets all three to 1.
This is an old-path/new-path comparison, not a previous-release binary comparison.
Three runs per leg; reported FPS is mean of runs 2 and 3, discarding warm-up.

| Machine | Resolution | Before runs | After runs | Before FPS | After FPS | Change |
| --- | --- | --- | --- | ---: | ---: | ---: |
| G3 Yosemite, Tiger, Rage 128 | 800x600 | 38.0 / 39.3 / 39.3 | 36.7 / 36.7 / 36.8 | 39.30 | 36.75 | -6.5% |
| G4 mini, Tiger, Radeon 9200 | 1024x768 | 40.4 / 40.1 / 40.8 | 40.3 / 40.2 / 40.3 | 40.45 | 40.25 | -0.5% |
| G4 Quicksilver, Tiger, Radeon 9000 | 1024x768 | 57.9 / 58.0 / 57.9 | 62.0 / 58.9 / 61.8 | 57.95 | 60.35 | +4.1% |

Raw evidence for this session: `/private/tmp/q2-ppc-ab/results.csv` and
`/private/tmp/q2-ppc-ab/raw/`. These temporary paths are not durable archives.
CSV commit identifies the base commit; notes identify the uncommitted source stamp.
Quicksilver passes all ten reference-frame comparisons (maximum normalized
RMSE 0.00763729, threshold 0.04). G4 mini passed the earlier candidate frame
comparison in this conversation. G3 frame validation remains incomplete:
the screenshot helper produced no frames; a retry stalled at video initialization.
Sawtooth is unreachable. G3 was tested on Tiger, not Panther.

The Quicksilver after runs vary materially; repeat before changing defaults.
The G4 mini difference is small relative to observed run variation.
Do not enable all three on the G3 based on these results.

## Review priorities (not implemented)

1. Separate retained geometry from per-frame qsort. The comparator prioritizes
   depth bands before material/lightmap, which can split otherwise compatible
   batches. Test no-sort and inexpensive buckets independently; retain useful
   visibility/depth ordering where overdraw dominates.
2. Benchmark bounded compiled-array locks on the new client-array draws, and
   16-bit indices in world chunks. Existing array paths use compiled-array
   locks; new world/alias/shadow draws omit them. World indices are 32-bit.
   G3 logs confirm compiled-array support. Do not lock an entire large map
   blindly; bound ranges and measure actual driver behavior.
3. Remove allocator churn from the direct-mapped light cache. Collisions with
   differing surface sizes free/reallocate storage during rendering. Use a
   bounded reusable arena/pool and measure hit rate, eviction rate and upload
   bytes. Separate CPU caching, column bounds and grouped uploads into
   independently measurable switches. G3's profile disables dynamic lighting,
   so this is not established as its slowdown source.

These are source-supported improvement candidates, not proven FPS fixes.
Single-switch benchmarks are needed to attribute the combined results.
