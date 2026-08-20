---
name: fleet-optimize
description: Find and apply the next fps or graphics-quality win for the old-Mac Quake II (yquake2) port across the shared bench fleet (G3/Rage128, G4/GeForce2·Radeon9000·9200, Intel-Lion/GMA950, G5/Radeon9600). Re-runnable, each run profiles one target machine class, forms ONE bottleneck-matched hypothesis, implements it cvar-first (then code, gated behind a cvar so one fat binary auto-tunes per machine), benches it safely, keeps or reverts, records it, and says whether more wins remain. Use whenever the user wants more fps, more graphical features, or asks to "optimise/tune" any old Mac.
---

# fleet-optimize: one optimization iteration

Goal: the best-looking build that stays **playable** on each machine class,
controlled entirely by **cvars from one fat binary** (auto-configured by
`hw.model`). This runs **one** disciplined iteration; invoke it again for the
next. It is the optimization loop, not the build system.

## Read before touching anything

- `MISTAKES.md`, what already broke. **Never re-chase a recorded negative.**
- `docs/adr/0009`, how to bench and smoke test safely, and the floors.
- `docs/adr/0010`, the A/B rule and the measured cost of every shipped default.
- `docs/adr/0008`, the iMac G5 hazard. It can take the machine down for good.
- `docs/CONFIG.md`, exact cvar names.
- `benchmarks/results.csv`, your baseline.
- `scripts/bundle/autoexec-*.cfg`, each machine's shipped config.

## Non-negotiable rules

1. **cvar-first, one fat binary.** Every machine-specific knob is a cvar in the
   per-machine autoexec. Drop to code only when config is exhausted, and gate
   the new behaviour behind a cvar or a GL-extension check so the single fat
   binary still self-tunes. This is the whole deployment model.
2. **Bench safely.** Use `scripts/bench.sh <machine> <demo> <WxH>` only. Always
   `killall -TERM`, sleep, then `-KILL` as a backstop, a bare KILL
   black-screens the R300 G5. **Never trigger a non-native fullscreen mode
   switch on `imac-g5`**; it hard-hangs the whole OS and only the power button
   recovers it. Recover a wedged Mac with `ssh <m> '~/bin/qsreboot.sh'` and
   confirm it cycles. Never build two PPC slices on the same mini.
3. **Respect the envelope.** Floors: **G3 ≥ 20 fps, G4 ≥ ~40 fps**, G5 and
   modern uncapped. Above the floor, **effects beat fps** (user preference):
   prefer adding a graphical feature to chasing framerate nobody needs.
4. **Measure, do not guess.** Profile the target class first; know whether it is
   CPU-bound or fill-bound. A regression that scales the same at two
   resolutions is CPU-bound.
5. **Discipline.** Three runs, median of 2 and 3. Two commits, code then bench
   data. Tag CSV rows `(commit, machine, demo, res)`. Revert any regression.
   **Record every negative result** so it is never re-tried. Push only to
   `origin`, never upstream.

## The loop

1. **ORIENT**, read `results.csv` and the machine configs. Pick ONE machine
   class and ONE goal.
2. **PROFILE**, where does the frame go on that class?
3. **HYPOTHESIZE**, one change, matched to the bottleneck *and* to what that
   GPU actually supports.
4. **IMPLEMENT**, autoexec cvar preferred; engine code gated behind a cvar
   otherwise.
5. **BUILD + DEPLOY**, config only: redeploy the cfg. Code: `build-fat.sh`
   then `deploy.sh <machine>`; check the slice with `lipo`.
6. **BENCH**, 3 runs vs baseline. For a graphics change also grab a screenshot
   and look at it. **Bench correctness is not visual correctness**, broken
   maths can be faster.
7. **EVALUATE**, keep if fps improved, or a feature landed without dropping
   below the floor and it looks right. Otherwise revert.
8. **RECORD**, append to `results.csv`; commit; write up negatives in
   `MISTAKES.md`.
9. **REPORT**, state the win or loss and whether this class is exhausted.

## Machine classes

| Class | GPU envelope | Bound by | Best levers |
|---|---|---|---|
| **G3** (yosemite) | Rage 128, 16 MB, **no S3TC, no AltiVec**, GL 1.2 | GPU fill + ATI driver | 16-bit textures/framebuffer, resolution, effect detail, sound mix rate. Config only, compiler flags proven useless here |
| **G4** (sawtooth GF2 MX / quicksilver R9000 / mini-g4 R9200) | AltiVec, S3TC, 32-64 MB, no GLSL | mixed | texture compression, vertex-array submission, AltiVec in profiled hot loops, aniso where there is fill headroom |
| **Intel-Lion** (mini-intel GMA 950) | GL 1.4, no GLSL, weak fill, strong 2-core CPU | fill at native res | 16-bit framebuffer, texture compression, vsync |
| **G5** (imac-g5 R9600) | DX9-class, S3TC, aniso, AltiVec | CPU (970FX) on the demo | aniso, internal quality, more effects, least constrained |
| **Modern** (imac-2019) | huge | never the target | reference only; separates CPU-bound from GPU-bound |

Startup prints `GL_RENDERER` and the extension list, read it before enabling a
code path for a GPU. **This port pins yquake2 5.11, which has ONE renderer:**
`src/refresh/` builds a single `ref_gl.so` (GL 1.x fixed-function). The gl1/gl3
split is upstream-only; there is no renderer to choose (ADR 0002).

## Search space: cheapest first

**Config / cvar, no rebuild:** texture detail (`gl_picmip`), bit depth (16-bit
is a fill and bandwidth win), texture compression, anisotropy, framebuffer
depth, lighting and dynamic-light and particle detail, geometry and world
detail, present (`gl_swapinterval`, `cl_maxfps`), sound mix rate.

**Code, when config is exhausted:** vertex arrays where the GPU supports them,
gated by extension; AltiVec on profiled hot loops for ppc7400 and the G5, with
codegen verified by `otool -tV`, but read the AltiVec entries in `MISTAKES.md`
first, two attempts were net-negative and one produced warped geometry that
benched faster; cut overdraw and tighten culling; remove per-frame allocations;
16-bit internal texture formats; heap sizing to avoid paging on 128-256 MB
machines. Expose every new behaviour as a cvar.

## Toolbox

**Orchestration box:** read and grep `yquake2/`; `git log` for prior attempts;
cross-build via `build-fat.sh`.

**On the Macs:** `/usr/bin/sample` (Panther through Lion, no Xcode needed),
statistical profiler, needs a non-stripped slice. On mini-intel with Xcode
(Lion): Instruments Time Profiler and System Trace, OpenGL Driver Monitor and
OpenGL Profiler (call counts, driver stalls, VRAM), `otool -tV`, `atos`,
`gcc -pg` / gprof. CHUD/Shark on Tiger and Leopard for deeper PPC profiling if
present.

## Stop condition

Declare "no more optimizations" only when, for **every** machine class, the
remaining candidates are all recorded negatives or below the fps noise floor.
Log each negative so future runs converge instead of looping.
