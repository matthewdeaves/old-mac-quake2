# GeForce 9400 framebuffer and driver-stall investigation

2026-09-22. Diagnostic work only. No production code or default changes.
Target: mini-sl, Macmini3,1, Snow Leopard 10.6.8, GeForce 9400, native
1920x1080 fullscreen, demo2, swap interval 0. G3 and G5 untouched.

## Uninstrumented feature costs

Installed RC2 engine and renderer were unchanged for this sweep. Projected
shadows, combined clears and partial bloom restore stayed enabled. Three runs
per condition; warm result is the mean of runs 2 and 3, also their median.

| Bloom | Requested MSAA | Warm FPS |
| --- | --- | ---: |
| On | 2 | 44.35 |
| Off | 2 | 74.00 |
| Off | 0 | 147.25 |
| On | 0 | 82.30 |
| On, repeated baseline | 2 | 44.55 |

These are feature costs, not achieved optimisations. Turning effects off does
not satisfy the goal of keeping the picture. Raw logs and CSV: `controlled/`.
The CSV's `fat` label describes the installed production artifacts correctly
here. HEAD b2c63db7 identifies the repository; RC2 runtime provenance is in
the earlier `2026-09-22-framebuffer/intel-shadows/installed` evidence.

An initial sweep in `/private/tmp/q2-gpu-cost-sep22` was discarded as a normal
baseline. Explicit startup `gl_bloom 1` bypasses the auto-selection branch that
also enables partial restore. Its first warm result, 39.65 FPS, therefore used
full restore. The controlled sweep explicitly sets `gl_bloom_fastrestore 1`.
Do not call that initial result a regression in RC2.

## Pass attribution

Temporary diagnostic renderer, built through `scripts/build.sh lion`, paired
with the installed RC2 engine. Patch retained as `q2-gpu-instrumentation.patch`.
Its Mach time clock is Apple-only and this patch is NOT production-ready.
Mode 2 flushes the engine's pending vertex batch and measures CPU submission
elapsed time. Mode 1 additionally calls glFinish at each boundary. Both alter
the pipeline. These are CPU elapsed times including driver and completion
waits, not GPU hardware timer measurements. Never accept their FPS as a win.

Each leg skips 20 frames, then logs four complete 120-frame blocks. Remaining
partial frames are excluded. Equal-sized block means are averaged in
`stage-means.csv`; regenerate with `awk -f aggregate.awk passes/raw-*/*.log`.

| Leg | Probe mode | Bloom | Actual samples |
| --- | --- | --- | ---: |
| 1 | Asynchronous | On | 2 |
| 2 | Serialized | On | 2 |
| 3 | Serialized | Off | 2 |
| 4 | Serialized | Off | 0 |
| 5 | Serialized | On | 0 |
| 6 | Serialized, repeat | On | 2 |

Actual GL sample-buffer/sample queries returned 1/2 for MSAA2 and 0/0 for
MSAA0. Raw context queries are in the corresponding logs. The thin diagnostic
renderer is NOT fat; `passes/instrumented-not-benchmark.csv` inherits a `fat`
label from the benchmark script and must not be read as artifact verification.

Selected measured elapsed times, milliseconds per frame:

| Stage | Async, bloom/MSAA2 | Serialized, bloom/MSAA2 | Serialized, bloom/MSAA0 | Serialized repeat, bloom/MSAA2 |
| --- | ---: | ---: | ---: | ---: |
| World | 1.8400 | 6.4951 | 5.7118 | 6.5871 |
| Entities and shadows | 1.0376 | 2.7193 | 2.3499 | 2.7380 |
| Full-view capture | 0.0693 | 3.5399 | 2.1738 | 3.5520 |
| Bloom restore | 0.0280 | 0.3354 | 0.3316 | 0.3354 |
| Bloom composite | 0.0135 | 2.5804 | 1.6513 | 2.5780 |
| Swap | 18.5731 | 3.4088 | 0.0512 | 3.4318 |

With bloom off, serialized swap still costs 3.4344 ms at MSAA2 versus
0.0489 ms at MSAA0. Prior-to-view wait includes current-frame pre-view work
such as clears, not solely the preceding frame. Stage times cannot be
subtracted from normal frame time as predicted savings: glFinish removes
overlap and adds synchronization overhead, especially to the small passes.
Logging also perturbs the run. No GPU utilization percentage was measured.

## Interpretation and next experiment

Measured: a large asynchronous wait moves from presentation into rendering
passes when each pass is forced to finish. Bloom capture and composite are
substantial, repeatable costs. A residual presentation cost tracks MSAA even
without bloom. World rendering also remains substantial.

Inference: framebuffer bandwidth, multisample resolve/copy work and driver
presentation work deserve attention before small CPU-loop changes. The exact
driver operation behind the residual swap delay is not proven by this probe.

Next hypothesis: keep antialiased 3D rendering and shadows, but resolve the
scene once into a single-sample full-resolution target, then perform bloom
and presentation without another multisampled back-buffer round trip. This
needs an extension-gated, cvar-controlled experiment and full image comparison,
not a default change. The captured extension list advertises
GL_EXT_framebuffer_object, GL_EXT_framebuffer_multisample and
GL_EXT_framebuffer_blit on this GPU. Availability is not proof that the path
is correct or faster. Extra scene storage may offset the hoped-for gain.

This differs from the recorded negative small bloom-workspace FBO experiment:
that left the full-view capture and final multisampled presentation in place.
Do not repeat that rejected implementation. Do not generalize these results to
Rage 128, GMA 950 or Radeon hardware without separate measurements.

## Restoration and checks

All temporary source instrumentation removed. Renderer tests and repo
invariants passed after restoration; logs retained here. Diagnostic thin build
moved out of the normal build input directory to
`build/diagnostics/q2-lion-gpu-stalls-20260922`. A fresh Lion build is needed
before the next fat assembly; existing RC2 fat artifacts and DMG are unchanged.

Installed renderer restored to MD5 dcfde8e72664968edd16f15f298d785b;
normal config restored to MD5 01604d6f6c2b583bd9fcfeb25756914a. Before/after
hashes retained. Picker reports mini-sl free, zero game processes. Every run
used `s_initsound 0`; normal config retains sound disabled. OS mute commands
were also issued, but engine-side disabling is the verified silence mechanism.
Temporary remote configs removed; remote backup directories retained.

`passes/frame03.png` inspected at native resolution: scene, projected shadows
and bloom present, no obvious corruption. This is a diagnostic screenshot,
not a formal pixel-equivalence test. Drivers/configs are retained for provenance;
they use absolute temporary paths and must be reviewed before any rerun.
Evidence remains local, no diagnostic code pushed or new release produced.
