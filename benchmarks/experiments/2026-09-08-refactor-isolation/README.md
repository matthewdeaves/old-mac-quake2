# Refactor isolation and sorting experiment

Pause correction: the later screenshot checks invoked a hyphenated cfg
name through +exec. Cbuf_AddLateCommands truncates at '-', so those checks
did not establish the requested settings despite passing image comparisons.
Treat sort/quicksilver-frames.log and confirmation/mini-g4-frames.log as
configuration-unverified. Direct +set timedemos below remain valid. See
NEXT-MODEL.md for completed G3 isolation, the subsequent opt-in lock code,
invalid lock benchmarks and the user's commit-and-pause instruction.

All runs use demo1, 1024x768 fullscreen on the G4s, bloom off, three runs.
Reported FPS is the mean of warm runs 2 and 3. Other graphics settings retain
the machine profile. No release, commit, or machine-profile change was made.

## Individual switches, original candidate

Source stamp: `447739046bce38aa86b03e703a33a09612453d631e24e4332f40b97b45d9c7a1`.
See `isolation.csv` and `raw/`.

| G4 mini setting | Warm FPS |
| --- | ---: |
| Retained world only | 40.30 |
| Indexed models only | 40.50 |
| Light cache only | 41.05 |

The earlier all-off baseline was 40.45. A later fresh baseline was 40.85;
do not interpret the earlier small differences as robust gains.

G3 isolation did not complete. The world-only run stalled after map loading;
the engine remained in process state U after TERM and KILL. Its benchmark
sequence was stopped and a normal reboot requested. Following reboot,
the configured yosemite-tiger SSH key was rejected. The yosemite alias has a
host-key mismatch; host verification was not bypassed or edited. User was
asked to check Tiger/login state. This does not establish that the world-only
switch caused the stall: an earlier screenshot run also stalled in video init.

## Implemented experiment

Added `gl_worldsort` (default 1, preserving the original candidate):

- `1`: existing depth/material/lightmap sort.
- `0`: preserve BSP collection order; skip per-surface depth-band calculation
  and per-frame qsort, while retaining cached geometry.
- Depth-band calculation is also skipped when retained geometry is off.

Source stamp: `5119fb937c91a0a5ff45224fcf18c46952301deff62b3ebbe3de7b1458e28aeb`.
All six slices built and fused successfully. Deployed renderer MD5 on both
G4s matched `cbd08c99d123744a35a192fa0f91299b`.
Sanitizer renderer harness, repository invariants and diff whitespace checks pass.

## Sorting comparison

World geometry on, indexed models and light cache off. See `sort/`.

| Machine | Sort on | Sort off | Change |
| --- | ---: | ---: | ---: |
| G4 mini | 40.30 | 40.90 | +1.49% |
| Quicksilver G4 | 60.15 | 60.00 | -0.25% |

The Quicksilver capture passed all ten reference comparisons, maximum normalized
RMSE 0.00763729, threshold 0.04, but its requested cfg was not verified (see
pause correction). Evidence: `sort/quicksilver-frames.log`.

## Fresh baseline versus combined setting

See `confirmation/`. Both legs use the new candidate.

| G4 mini setting | Runs | Warm FPS |
| --- | --- | ---: |
| All original refactors off | 40.8 / 40.9 / 40.8 | 40.85 |
| World on, sort off, indexed models off, light cache on | 41.2 / 41.2 / 41.2 | 41.20 |

The combined gain is 0.86%, not the larger figure obtained by comparing
against the earlier lower baseline. It preserves the same requested effects.
This is one demo/resolution; no broad performance or frame-pacing claim.
The G4 mini capture passed all ten reference frames at threshold 0.04,
but its requested cfg was not verified (see pause correction).
See `confirmation/mini-g4-frames.log`.

Compiled-array/16-bit-index changes and cache allocator changes were not
implemented in this experiment. G3 measurements are still required before
deciding how to address its earlier all-on regression. No fleet defaults
were changed on the strength of these small G4 results.
