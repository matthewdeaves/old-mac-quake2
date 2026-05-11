# Quake II PPC port — plan

Goal: most graphically advanced Quake II that runs playably on the 6-machine
retro Mac fleet (yosemite G3, sawtooth/quicksilver/mini-g4 G4s, mini-intel
Lion, imac-2019 Sequoia). Same playability floors as the QuakeSpasm
project: ≥ 20 fps on G3, ≥ 60 fps on G4/Lion.

This document is a living plan. Update at the end of each phase.

## Why three engines on disk

We start from one engine source (yquake2 5.11) and pull selectively
from two others. Each has a distinct role:

| Repo | Role | Why |
|---|---|---|
| `yquake2/` (5.11 tag) | **Base engine** | Last release with native SDL 1.2; has working OS X support (`sdl_osx/`); renderer/SDL split is clean for cherry-picking. |
| `reference/yquake2-latest/` | Phase B source | GL1 renderer got substantially better post-5.11: water warp, multitexturing, group draw calls, dlight optimization, gamma, overbrightbits, texture filter menu. All renderer-only — independent of SDL version. |
| `reference/kmquake2/` | Phase C source | Visual-effects king: bloom, decals (`r_fragment.c`), fog (`r_fog.c`), ARB shader programs, hi-res texture autoload, transparent surfaces with lightmaps, Quake2maX particles. No Mac code, so we port features, not the engine. |
| `reference/fod-quake2/` | Mac Cocoa polish | Optional. If yquake2's `SDLMain.m` boilerplate launcher is good enough we don't need this. |

## Phase A — bring-up (target: all 6 machines run vanilla yquake2 5.11)

The smallest plausible scope that gets fps numbers on the board.

### A.1 Cross-compile yquake2 5.11 on mini-intel

- Adapt `scripts/build.sh` from QuakeSpasm. Key differences:
  - Engine source is at `yquake2/` (top level), not `yquake2/Quake/`
  - Makefile is at `yquake2/Makefile`, not a Darwin-specific one
  - Override `OSX_ARCH`, `CC`, add `-isysroot`/`-mmacosx-version-min`
    via `CFLAGS` and `LDFLAGS` env vars
  - Disable `WITH_OPENAL`, `WITH_OGG`, `WITH_CDA` for first build
    (extra deps; revisit in A.3 once core works)
  - Keep `WITH_RETEXTURING=yes` (we want hi-res textures from day 1)
  - Build artifacts: `release/quake2`, `release/ref_gl.so`,
    optionally `release/q2ded`
- Same flock-serialization as QuakeSpasm to prevent g3/g4 parallel races
- Output: `build/q2-g3` (binary + ref_gl.so), `build/q2-g4`, `build/q2-lion`

### A.2 Bundle into a Tiger/Panther-compatible .app

- Adapt `scripts/deploy.sh`. yquake2's `OSX_APP := yes` Makefile target
  builds a Quake II.app structure — read what it generates, decide
  whether to use it directly or rebuild bundle assembly ourselves.
- Reuse `~/quakespasm/MacOSX/SDL.framework` (fat with Panther PPC slice)
- Bundle layout (probable, modeled on QuakeSpasm):
  ```
  Quake2.app/Contents/
    Info.plist
    MacOS/
      quake2
      ref_gl.so  (or embedded — TBD per Makefile output)
      SDL.framework/
    Resources/
      Launcher.nib  (if we use one — yquake2 5.11 ships SDLMain.m
                     which doesn't need a launcher NIB)
  ```
- Pass `-nolauncher` equivalent or just rely on SDLMain.m's direct boot.

### A.3 Tiger/Panther patches

Build will fail; patch until it doesn't. Expected (from QuakeSpasm experience):
- `kCGLCEMPEngine` ifdef guard for 10.3.9 SDK
- NSAlertStyle macros for 10.4
- NSString encoding fallback for 10.3 (probably not — SDLMain.m is simpler than FoD's stack)
- Possibly Obj-C 2.0 dot notation if any .m files use it

Commit each patch as a separate `patch: <description>` commit.

### A.4 Deploy + verify on all 6 machines

- `deploy.sh yosemite` / `sawtooth` / etc.
- Run `quake2 -nolauncher +timedemo demo1.dm2`
- Capture qconsole.log via `-condebug`
- Adapt `scripts/bench.sh` for Q2 demo filenames and timedemo output format

### A.5 Baseline benchmark

- `parallel-bench.sh --quick` (demo1 × 1024×768 + 640×480 × 3 runs)
- Commit baseline to `benchmarks/results.csv`
- Phase A complete when all 6 machines have valid baseline numbers
  and no machine crashes mid-demo.

**Phase A success criteria:** vanilla yquake2 5.11 runs cleanly on all
6 machines, baseline fps captured. **No optimizations, no visual
upgrades.** This is the floor.

**Risk to flag:** if G3 baseline on demo1 1024×768 is under ~5 fps,
we may need to scope back ambition on yosemite (possibly switch to
640×480 default like QuakeSpasm did) or accept G3 as a "best effort"
target rather than a hard floor.

---

## Phase B — GL1 renderer cherry-picks from yquake2 latest

All of these are renderer-only changes (touch `src/refresh/*.c`) and
should apply cleanly against the 5.11 base since the post-5.11 SDL
backend churn doesn't reach into the renderer.

Cherry-pick + bench + commit one at a time. Each is a candidate
PPC_PLAN.md "phase" in the QuakeSpasm sense — own commit, own bench,
own row in the toggles table.

| Cherry-pick | What | Expected impact |
|---|---|---|
| **B.1 Water warp for GL1** | yquake2 5.11 has no water warp on GL1 (only software renderer). Latest added it. | Visual upgrade. Modest fps cost (per-pixel warp on water surfaces). Toggle: `gl1_waterwarp` cvar. |
| **B.2 GL1 multitexturing** | Latest reimplemented multitex for GL1. 5.11 walks two passes. | Pure fps win on multi-light surfaces. Toggle: `gl1_multitexture` cvar. |
| **B.3 Group draw call** | Batch consecutive same-material draws into one GL call. Latest's changelog: "huge perf gains on slow GPUs." | **Likely big G3 win** (Rage 128 is submission-overhead bound). Toggle: `gl1_groupdraw` cvar. |
| **B.4 Dynamic light + texture allocation opt** | Several latest commits. | Demo3 win expected (dlight-heavy demo). |
| **B.5 GL1 gamma correction** | 5.11 has no GL1 gamma (only software). | Visual quality. No fps cost. Toggle: `gl1_gamma` cvar. |
| **B.6 Overbrightbits** | `gl1_overbrightbits` 0/1/2/4. | Visual quality (brighter highlights). |
| **B.7 Texture filter menu** | UI-level — texture filter is currently a console cvar. |
| **B.8 gl1_particle_square** | Toggle square vs. round particles for fixed-function. | Visual + minor fps on R128 (square = faster point sprites). |

**Each item gets:** cherry-pick commit → smoke bench → if no
regression, official `bench-and-commit.sh` row. Same cadence as
QuakeSpasm Phase 2.x/3.x.

Phase B success: every applicable item landed, full-grid bench at end
shows cumulative improvement on at least demo3 + demo1 across all 6
machines. (Some items may be no-ops on specific GPUs — that's fine,
they still get an "(N/A)" row in the toggles table.)

---

## Phase C — Visual features from KMQuake2

By this point we have a stable, optimized GL1 renderer. Phase C is
where we cash in on the "most graphically advanced" goal. Each
feature is its own mini-project, gated behind a cvar, with per-target
defaults tuned to the GPU envelope.

| Feature | KMQuake2 source | Target GPUs (default ON) | Risk |
|---|---|---|---|
| **C.1 Hi-res texture autoload** (TGA/JPG/PNG) | `r_image.c` 63K | All (vram-permitting) | Low — yquake2 already has `WITH_RETEXTURING`; align with KMQuake2's loader. **Rage 128 has only 16 MB VRAM** — gate behind a max-texture-size cvar. |
| **C.2 Fog (fixed-function GL_FOG)** | `r_fog.c` 4K | All (G3/G4/Lion/Sequoia) | Low — fixed-function fog is universally supported. Visual mood lift. |
| **C.3 Decals** | `r_fragment.c` 8K | All | Low-med — decal management is its own subsystem, but fixed-function compatible. |
| **C.4 Alpha-test surfaces with lightmaps** | KMQuake2 r_surf changes | All | Low — fixed-function blend mode change. Improves textures with cutouts (foliage, grates). |
| **C.5 Bloom (ARB fragment program)** | `r_bloom.c` 21K + `r_arb_program.c` 10K | mini-g4 (Radeon 9200), quicksilver (Radeon 9000), mini-intel (GMA 950), imac-2019 (580X) | High — needs ARB_fragment_program. **Skip on yosemite (Rage 128) and sawtooth (GeForce2 MX)** — fixed-function only. |
| **C.6 Quake2maX particle effects** | `r_particle.c` 30K | All (with quality dial) | Med — much fatter particle code than 5.11's. Use `cl_particles_quality` cvar (low/med/high) per-target. |
| **C.7 Transparent surfaces with lightmaps** | KMQuake2 r_surf changes | All | Low — fixed-function blend stage. |
| **C.8 ARB stencil shadows** | KMQuake2 alias shadow code | mini-g4, quicksilver, mini-intel, imac-2019 | Med — needs stencil buffer. R128 may not have one. **Toggle per target.** |

Per-target defaults will go in `scripts/bundle/autoexec-<machine>.cfg`
files, same scheme as QuakeSpasm.

**Phase C is open-ended** — we pick features as we go based on fps
budget remaining. The QuakeSpasm goal-trade frame applies: "visual
upgrades that cost 10-15% fps are in scope if they leave the cell
above its playability threshold."

---

## Open questions (defer until they bite)

1. **Bundle structure:** does yquake2 5.11's `OSX_APP := yes` Makefile
   target produce a sane Tiger-compatible .app, or do we need to
   build it ourselves with a template like QuakeSpasm? Answer in A.2.
2. **ref_gl.so packaging:** loaded as a dlopen() plugin or linked into
   the main binary on macOS? Affects how we ship the renderer.
3. **OpenAL / OGG**: do we want these on PPC? OpenAL adds a dep and
   the audio benefit is marginal on these speakers. OGG music is
   nice-to-have. Defer to post-A.5.
4. **Mission packs:** the user has CTF data on quicksilver, but no
   pak files for rogue/xatrix. Sourcing those is out of scope for
   the optimization work — the user can drop them in any time.
5. **Q2 Remaster (Nightdive) integration:** `yquake2remaster` is
   alpha-quality. If it stabilizes and the Mac side works, it might
   be a future major-version base. Far future.

---

## Status

- 2026-05-11 — project initialized at yquake2 QUAKE2_5_11. Phase A
  not started. Scripts not yet adapted. Quicksilver `~/Desktop/Quake 2/`
  not yet tidied (proposal in `scripts/tidy-quicksilver.sh`).
