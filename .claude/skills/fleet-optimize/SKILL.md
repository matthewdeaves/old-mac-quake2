---
name: fleet-optimize
description: Find and apply the next fps or graphics-quality win for the old-Mac Quake II (yquake2) port across the shared bench fleet (G3/Rage128, G4/GeForce2·Radeon9000·9200, Intel-Lion/GMA950, G5/Radeon9600). Re-runnable — each run profiles one target machine class, forms ONE bottleneck-matched hypothesis, implements it cvar-first (then code, gated behind a cvar so one fat binary auto-tunes per machine), benches it safely, keeps or reverts, records it, and says whether more wins remain. Use whenever the user wants more fps, more graphical features, or asks to "optimise/tune" any old Mac.
---

# fleet-optimize — one optimization iteration for the old-Mac fleet (yquake2 / Quake II)

Goal: the best-looking build that stays **playable** on each machine class,
controlled entirely by **cvars from one fat binary** (auto-config by `hw.model`).
This skill runs **one disciplined iteration** — invoke it again for the next.
It is the optimization *loop*; it uses the build/deploy/bench mechanics, it does
not reinvent them.

## Before you touch anything — read these (they encode hard-won limits)
- `MISTAKES.md` — what already broke. **Never re-chase a recorded negative.**
- `docs/BENCH.md` — how to benchmark/profile on real hardware + known hotspots.
- `docs/CONFIG.md` — the exact cvar names and what they do.
- `benchmarks/results.csv` — current per-machine fps (your baseline).
- `scripts/bundle/autoexec-*.cfg` — each machine's shipped config.

## Non-negotiable rules
1. **cvar-first, one fat binary.** Every machine-specific knob is a cvar in the
   per-machine autoexec; auto-config picks them by `hw.model`. Drop to code only
   when config is exhausted or the win needs it — and then **gate the new
   behaviour behind a cvar / GL-extension check** so the single fat binary still
   serves every machine and self-tunes. This is the whole deployment model.
2. **Bench safely — never wedge a machine.** Use `scripts/bench.sh <machine>
   <demo> <WxH>` only; it encodes the fleet's safe single-session bench pattern.
   **Never KILL a fullscreen app** (it can wedge the GPU driver until a reboot).
   Recover a wedged Mac with `ssh <m> '~/bin/qsreboot.sh'` and confirm it cycles.
   Don't build g3 + g4 in parallel.
3. **Respect the envelope.** Floors/targets: **G3 ≥ 20 fps, G4/Lion ≥ 60 fps**,
   G5/modern uncapped. Above the floor, **effects > fps** (user preference): prefer
   adding a graphical feature to chasing fps nobody needs.
4. **Measure, don't guess.** A change without a known bottleneck is a guess.
   Profile the target class first; know if it's CPU-bound or fill-bound.
5. **Discipline.** 3 runs, median of 2 & 3; two commits (code, then bench data);
   tag CSV rows `(commit, machine, demo, res)`; **revert any regression**; and
   **record negative results** in the docs so they're never re-tried.
   **Push only to my fork (`origin`), never upstream.**

## The loop (one iteration)
1. **ORIENT** — read the baseline (csv) + the machine configs. Pick ONE target
   machine class and a goal: raise fps toward its target, or add a graphical
   feature within its budget.
2. **PROFILE** — where does the frame go on that class? CPU-bound → CPU levers;
   fill-bound → pixel/fill levers. Use the toolbox below.
3. **HYPOTHESIZE** — pick ONE change from the search space, matched to the
   bottleneck AND to what that GPU actually supports (see the class table).
4. **IMPLEMENT** — edit the machine's autoexec cvar (preferred) or the engine
   code (`yquake2/`), gated behind a cvar.
5. **BUILD + DEPLOY** — config only: re-deploy the cfg. Code: `scripts/build-fat.sh`
   (serialized) then `scripts/deploy.sh <machine>`; sanity-check the slice chip.
6. **BENCH** — `scripts/bench.sh <machine> <demo> <WxH>`, 3 runs vs baseline.
   For a graphics change, also grab a screenshot and eyeball it.
7. **EVALUATE** — keep if fps improved, or a feature was added without dropping
   below the floor and it looks right. Otherwise **revert**.
8. **RECORD** — append to `benchmarks/results.csv`; commit (code then bench);
   update the docs with what you learned, negatives included.
9. **REPORT** — state the win/loss and whether this class's search space is now
   exhausted. If **every** class has only recorded negatives left → declare done.

## Machine classes — what each supports & where the wins are
| Class (machine) | GPU envelope | Bound by | Best levers |
|---|---|---|---|
| **G3** (yosemite) | Rage 128, 16 MB, **no S3TC, no AltiVec**, GL 1.2, fixed-function | GPU fill + ATI driver | 16-bit textures/framebuffer, resolution, effect detail, **sound mix rate**. Config only — compiler flags proven useless on the G3. |
| **G4** (sawtooth GeForce2 MX / quicksilver Radeon 9000 / mini-g4 Radeon 9200) | AltiVec CPU, S3TC, 32–64 MB, fixed-function, no GLSL | mixed | **S3TC / texture compression** (free detail), **VBO/vertex-array** submission, **AltiVec** in profiled hot loops, aniso where fill headroom. |
| **Intel-Lion** (mini-intel GMA 950) | GL 1.4, no GLSL, weak fill, **strong 2-core CPU** | fill at native res | 16-bit framebuffer, texture compression, **vsync** (tearing), threading where the engine supports it. |
| **G5** (imac-g5 Radeon 9600) | DX9-class, S3TC, aniso, AltiVec, fast | most headroom | push aniso, higher internal quality, more effects — least constrained; MAX it. |
| **Modern** (imac-2019 Sequoia) | huge | never the target | reference only — separates CPU-bound from GPU-bound effects. |

Startup console prints `GL_RENDERER` + the extension list — **read it to know
exactly what a GPU supports** before enabling a code path for it. Note yquake2
ships both a GL1.4 (`gl1`) and a GL3 renderer — the old GPUs need **gl1**; GL3/GLSL
is only for the G5/modern-Intel end.

## Optimization search space (cheapest → deepest)
**Config / cvar (no rebuild — always try first):** texture detail (`gl_picmip`) +
**bit depth** (16-bit = fill/bandwidth win), texture **compression**
(`gl_ext_*compress*`), anisotropy; **framebuffer depth** (16-bit — fill win on
Rage128/GMA); lighting / dynamic lights / particle detail; geometry & world
detail; present (`gl_swapinterval` / vsync, `cl_maxfps`); **sound mix rate** (CPU
win on the G3); renderer choice (`vid_renderer gl1` on the old GPUs).
*Consult `docs/CONFIG.md` for the exact cvar names.*

**Code (rebuild — when config is exhausted or the win needs it):**
- **Vertex submission** — prefer VBO / vertex arrays where the GPU supports it;
  cuts per-frame CPU submission churn. Gate by GPU / GL extension.
- **AltiVec** the profiled hot loops on ppc7400/G5; verify codegen with `otool -tV`.
- Cut overdraw / tighten culling; remove per-frame allocations in the frame loop.
- Texture upload: 16-bit internal formats; avoid re-upload churn.
- Memory / heap sizing to avoid paging on 128–256 MB machines.
Expose every new behaviour as a cvar → the one fat binary enables it per class.

## Toolbox
**This host (Linux):** read/grep the source (`yquake2/`); `git log` for prior
attempts; cross-build via `build-fat.sh` (mini-intel).
**On the Macs (analysis):**
- `/usr/bin/sample` (Panther→Lion, no Xcode) — statistical profiler; build a
  non-stripped slice, trigger on load-complete, sample the render thread.
- **mini-intel + Xcode (Lion):** Instruments (Time Profiler, System Trace),
  **OpenGL Driver Monitor / OpenGL Profiler** (GL call counts, driver stalls,
  VRAM), `otool -tV` (disasm — verify AltiVec/codegen), `atos`, `gcc -pg`/gprof.
- CHUD/Shark on Tiger/Leopard (G4/G5) for deeper PPC profiling if present.

## Stop condition
Declare "no more optimizations" only when, for **every** machine class, the
remaining candidates are all tried-and-recorded negatives (or below the fps noise
floor). Log each negative in the docs so future runs of this skill converge
instead of looping.
