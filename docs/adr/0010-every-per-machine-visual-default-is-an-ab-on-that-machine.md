# 10. Every per-machine visual default is an A/B on that machine

Date: 2026-08-20 (records practice from 2026-05-19 onward)
Status: accepted

## Context

Six GPU generations from a 1999 Rage 128 to a 2019 Polaris share one binary. GPU
class does not predict cost: features that are free on one 2004 ATI part cost
60% on another, and a driver can fall off a cliff on an operation the extension
string says it supports.

## Decision

**Every visual or performance knob is a cvar, defaulted per machine in
`scripts/bundle/autoexec-<machine>.cfg`, and no default is set without an A/B
benchmark on that machine.** Drop to code only when config is exhausted, and
then gate the new behaviour behind a cvar or a GL-extension check so the single
fat binary still serves every machine and self-tunes (ADR 0007).

Corollaries that have each been paid for:

- **"8-bit stencil was granted" is not "the stencil path is fast."** The
  `have_stencil` flag in `r_mesh.c` only checks that stencil bits were granted,
  so it cannot guard for a slow driver path. Bench-validate per machine before
  enabling any stencil-test feature on a 1999–2007 GPU.
- **Per-machine settings change which code paths are hot.** A cherry-pick
  justified by a sister-project measurement has to be re-checked against the
  target machine's own autoexec first. The lightmap subrect upload was queued
  for yosemite on a +4.2% figure from a box with dynamic lights on; yosemite's
  autoexec sets `gl_dynamic 0`, which gates the entire dynamic path in 5.11
  (`r_surf.c:279/429/651`), so `LM_UploadBlock(true)` never fires there and
  there was nothing to optimise.
- **A regression that scales identically at two resolutions is CPU-bound, full
  stop.** A bandwidth optimisation cannot fix CPU.
- **The same artifact on two different GPUs and drivers means a logic bug in
  shared code, not a driver state leak.**
- **Test the least forgiving machine, not four out of five.** "Green on G4, G5
  and Intel" has twice shipped something fatal on the Rage 128 G3 or the R300
  G5.
- **A change that needs a per-slice compile guard to be safe is the wrong fix
  for this fleet.** Prefer the mechanism that needs no special-casing.

## Measured costs behind the shipped defaults

| Feature | Machine | Measurement | Shipped |
|---|---|---|---|
| `gl_stencilshadow 1` | mini-g4 (R9200, Tiger) | demo2 1024x768 **103.6 → 40.6 fps**, a **60% regression**, 2026-05-23, pre-AltiVec | see note |
| `gl_stencilshadow 1` | imac-g5 (R9600, Leopard) | **116.1 vs 115.9 fps**, free | ON |
| `gl_stencilshadow 1` | mini-intel (GMA 950) | free; the demo is CPU-bound there | ON |
| `gl_msaa_samples` | imac-g5 @ native 1440x900 | 0x = **116**, 2x = **52.5**, 4x = **27 fps** | 2x |
| `gl_msaa_samples` | mini-g4 @ 1024x768 | **-1.5 fps** with 2x MSAA + decals | 2x |
| `gl_msaa_samples` | mini-intel (GMA 950) | 8x free (CPU-bound) | 8x |
| `gl_msaa_samples` | sawtooth | within noise | 0 (GF2 MX fixed-function) |
| `gl_dynamic 1` | sawtooth (GeForce2 MX) | **83 → 15 fps** @1024, **95 → 15** @640, ~80% | 0 + `gl_flashblend 1` (~69 fps) |
| `gl_bloom 1` | quicksilver (R9000 Pro) | demo1 1024 **66.95 → 25.50 fps**, **-62%** | 0 everywhere |
| Yosemite ULTIMATE (`gl_picmip 0`, `gl_round_down 0`, trilinear, alias shadows, `gl_fog 1`) | yosemite (Rage 128) | **31.50 → 25.10 fps** @1024, **65.30 → 45.15** @640 | ON (both above the 20 fps floor) |
| `gl_retexturing 1` | multitex boxes | <5% (decode is a one-time per-texture cost at map load) | ON above 32 MB VRAM |
| `gl_anisotropic 2` | sawtooth + yosemite | chip maximum for GF2 MX / R128; silently no-ops if the extension is missing | ON |

**Note on the G4 stencil rows.** The stencil-shadow decision was revisited on
2026-06-06 and the whole PPC fleet was switched on, on figures of mini-g4
127 → 108 (~15%), quicksilver 65 → 65 (zero), sawtooth 74 → 60 demo1 (~19%).
**Those figures came from the run that recorded `res=1` and therefore rendered
1x1 pixels** (ADR 0009). The 60% regression above is the only G4 stencil
measurement taken at a real resolution, and it predates the AltiVec work, so it
may no longer hold either. **Re-taking this decision is issue #7 and is open.**
Do not quote the 2026-06-06 numbers as current.

## Reference points

Vanilla yquake2 5.11, demo1, no optimisations, 2026-05-11 (the Phase A
baseline):

| Machine | 640x480 | 1024x768 |
|---|---:|---:|
| imac-2019 (Radeon Pro 580X) | 709.2 | 701.6 |
| mini-g4 (Radeon 9200) | 126.9 | 99.2 |
| mini-intel (GMA 950) | 59.4 | 116.0 |
| sawtooth (GeForce2 MX) | 95.0 | 82.9 |
| quicksilver (Radeon 9000) | 82.7 | 82.1 |
| yosemite (Rage 128) | 18.4 | 14.7 |

The mini-intel 640x480 figure is lower than its 1024x768 one because Quartz
vsync gated it at 60; 1024x768 did not match a native mode, so SDL dropped into
a non-vsynced path. That vsync default was later fixed and is worth +275% at
640x480 there.

Bottleneck per machine, as established by resolution sweeps: **yosemite is GPU
fillrate-bound** (Rage 128); **sawtooth is CPU-bound** on `R_BuildLightMap`;
**quicksilver is vsync-capped with unused GPU headroom**; **mini-g4 is mixed**;
**imac-g5 is CPU-bound on the 970FX**; **mini-intel and imac-2019 have margin**.
Startup prints `GL_RENDERER` and the extension list, read it before enabling a
code path for a GPU.

Current shipped figures live in `README.md` and every row in
`benchmarks/results.csv`.

## Consequences

- Adding a machine class means benching it, not classifying it.
- Recorded negatives are load-bearing: `MISTAKES.md` exists so a settled
  negative is never re-chased. Read it before starting anything that smells
  "easy / load-time only / zero risk".
