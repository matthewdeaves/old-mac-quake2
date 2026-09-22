# Resolve-once scene experiment

2026-09-22. Code: `594c5d0bb1a3253a7ff5a82d778a165f4ed4f5af`.
Kept as an opt-in experiment, `gl_scene_resolve 1`, default 0. No machine
profile changed. This is a measured GeForce 9400 improvement, not a fleet-wide
claim or a new release. The preceding investigation is in `../2026-09-22-gpu-stalls/`.

## Measured performance

mini-sl, Macmini3,1, Core 2 Duo 2.26 GHz, GeForce 9400, Snow Leopard 10.6.8.
Native 1920x1080 fullscreen, VSync off. Bloom, projected shadows, combined
clears and two-sample scene antialiasing retained. Audio initialization disabled.
Each leg has three runs; the warm result is the mean of runs 2 and 3, also
their median. No profiling timers or glFinish instrumentation in these runs.

| Demo | Existing A | Resolve B | Resolve B repeated | Existing A repeated |
| --- | ---: | ---: | ---: | ---: |
| demo2 | 44.55 | 51.40 | 51.10 | 44.55 |
| demo1 | 45.15 | 51.95 | 51.95 | 44.75 |

Averaging the warm legs gives demo2 44.55 to 51.25 FPS, about 15.0%, and
demo1 44.95 to 51.95 FPS, about 15.6%. Raw evidence is in `bench/`.
These exploratory rows identify the starting HEAD b2c63db7 and a dirty-tree
source stamp. Their `fat` field is inherited from bench.sh; the trial renderer
was thin x86_64 beside the installed RC2 fat engine. Notes identify this.

The final six-slice renderer repeated demo2 at 44.10 versus 51.25 FPS in
`final/`, still paired with the unchanged installed RC2 engine. Subsequent
post-code-commit rows are recorded directly in `benchmarks/results.csv` under
594c5d0b; their raw logs are in `recorded/`. Those are the canonical rows.
The canonical pair is 44.55 versus 51.20 FPS, a 14.9% increase.
Do not mix the VSync-off results with normal VSync-on presentation rates.

## What changed

The old path renders into a multisampled window, captures the full scene,
uses the back buffer for bloom work, restores the overwritten corner, and
composites bloom into that multisampled window.

The experiment renders into a full-resolution multisampled scene framebuffer
with packed depth/stencil. It resolves straight into bloom's existing screen
texture once. Bloom and the HUD then render into a single-sample window.
The final scene restore must cover the whole view, since the window no longer
contains the scene. A bloom-off or reduced-view frame instead resolves to the
window and uses the original path. Menu/loading frames also get presented.

Actual allocation queries on the target report requested 2, color samples 2,
depth samples 2, window samples 0. Both initial resolve and presentation blits
report GL error 0. This does not substitute no-AA rendering for the requested
antialiased scene. The HUD/postprocess are deliberately single-sampled.

The implementation uses extension-gated framebuffer storage and blits, no
shaders. API reference: [EXT_framebuffer_multisample](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_framebuffer_multisample.txt)
and [EXT_framebuffer_blit](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_framebuffer_blit.txt).
Unsupported explicit requests fail initialization with a diagnostic rather
than silently disabling AA. Native SDL 1.2 only; SDL12-compat is rejected.
This is not yet a default-on, universally falling-back rendering path.

## Image validation

Ordinary back-buffer captures were out of step between paths. Adjusting the
initial wait count to 49 or 51 did not establish a reliable pixel comparison.
Those early captures are not evidence of image equivalence.

A separate temporary validation renderer changed only screenshot readback to
GL_FRONT and logged render time/error. Both paths used `fixedtime 100` for
these images, never for FPS measurement. All ten paired captures report the
same render times and error 0. This controls the comparison; it does not
prove whether buffer selection or fixed timestep alone resolved the mismatch.

Full-resolution normalized RMSE across those pairs is recorded in
`front-frame-metrics.csv`: 0.00106375 through 0.0235312, including diagnostic
notification text. Frame03 is 0.00409272. They are not bit-identical.
Inspected native frame00 and frame03 pairs retain geometry, textures, bloom
and projected shadows without obvious corruption. Frame00 is the largest
numeric difference and is retained along with frame03 in `front/`.
The comparison script and all capture logs are retained. Remaining native
PNGs are in `/private/tmp/q2-scene-resolve-sep22/front/` for this session.

The front-capture patch is preserved here but removed from production source.
Its separate diagnostic artifact lives under `build/diagnostics/q2-lion-scene-front`.
Normal `build/q2-lion` was restored to the exact final source-stamped slice.

Reduced-view runtime returned zero bloom GL errors and showed the scene and
HUD; the capture also exposed a black area in the bottom-left decorative
border where the legacy bloom workspace sits. The baseline reduced-view capture
in `recorded/reduced03.png` has the same black border area with scene-resolve
disabled. This is a pre-existing bloom-workspace problem, not fixed by this
experiment. Reduced-view rendering is therefore not described as artifact-free.
Bloom-off fallback completed demo1 at 69.9 FPS, a one-run correctness check,
not an accepted effects-on performance result.

## Builds, tests and scope

Final runtime source stamp:
`1fca212880d5f1dc399a9ed52f2632bc1eef7fdacf4f8c803eb9970d4b606aa3`.
The source stamp matched again after removing temporary capture instrumentation.
All four fat products passed numeric architecture checks for ppc750, ppc7400,
ppc970, x86_64, i386 and arm64. Building PPC slices did not access the G3/G5.

Address/undefined-sanitized renderer tests cover full/reduced views, disabled
path, single resolve, framebuffer/scissor restoration, extension token
boundaries and bloom full-scene restoration. Repo invariants and Mach-O parser
fixtures passed. The new scene module has no findings from the local cppcheck
and clang pass; the broader renderer analysis still reports existing findings,
so it is not described as warning-free. Code GitHub Actions35740916630 passed.

Every trial restores the original installed renderer and normal config, with
before/after hashes retained. Production renderer MD5 is
dcfde8e72664968edd16f15f298d785b; config MD5 is
01604d6f6c2b583bd9fcfeb25756914a. Normal sound remains disabled. All actual
benchmark/capture runs explicitly disable sound initialization, and OS mute
commands were issued as well. The G3 remains untouched with its existing
shadow-enabled build. No G4/G5 runtime results are claimed for this change.

Next acceptance work before a default-on release: longer gameplay including
base1/new-game and menu transitions, and production packaging/install smoke.
Keep unsupported hardware on the existing path. More optimisation remains
possible, but this experiment already recovers about seven FPS while retaining
the selected scene effects. Drivers here contain session-specific absolute
temporary paths; review them before reusing them.
