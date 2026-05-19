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
- 2026-05-11 — Phase A.1 baseline builds working for lion + g4 + g3.
  All three targets cross-compile cleanly via `scripts/build.sh` on
  mini-intel. Three Phase A patches applied as separate commits:
  - `patch: gate -rpath on 10.5+ deployment target` (Makefile)
  - `patch: link Darwin shared libs with -dynamiclib, not -shared` (Makefile)
  - `patch: include sys/types.h before sys/mman.h on Panther 10.3.9 SDK` (hunk.c)

## Working approach (revised 2026-05-19)

After the initial Phase B/C breakdown above, Round 1 discoveries
narrowed the practical pipeline considerably:

- **Phase B multitex is a no-op** — 5.11 already calls
  `R_RenderLightmappedPoly` via the SGIS multitex path when available
  (r_surf.c:1172-1228). yquake2-latest adds a runtime toggle cvar
  but no new FPS code on the hot path.
- **Phase B group-draw is a 2024 multi-file refactor** by Jaime
  Moreira (`reference/yquake2-latest/src/client/refresh/gl1/gl1_buffer.c`
  + GLBUFFER_VERTEX/MULTITEX macros baked into every call site). Each
  cherry-pick conflicts with the directory rename (`refresh/` → `gl1/`)
  and the intermingled "Client & GL1 refactor" commits. Hand-port
  budget: multiple days. **Out of scope until Phase B becomes the
  bottleneck.**
- **QS lightmap subrect upload would not help G3** — the per-frame
  dynamic-lightmap upload at `r_lightmap.c:71` is gated by
  `gl_dynamic` which yosemite's autoexec already sets to 0. The +4.2%
  QS measurement came from a box with dlights on.
- **KMQuake2 decals are game-DLL-driven** — `R_AddDecal` is called
  from `g_combat.c`/`p_weapon.c` impact handlers. Pure renderer port
  doesn't deliver decals without modifying our `baseq2/game.so` source
  too. Bigger increment; deferred.
- **demo3.dm2 doesn't exist in retail paks** — Q2's demo set is
  `demo1.dm2` (intro) + `demo2.dm2` (gameplay) only. Bench scripts
  default to these two now.

### Round cadence

Each commit on master is **either**:
1. A new graphical feature gated behind a cvar, with the cvar wired
   into per-machine `scripts/bundle/autoexec-*.cfg` so each box opts
   in/out. Default OFF for safety; turn ON in autoexec for the GPU
   classes that can afford it.
2. A refactor / hotspot fix that reclaims FPS, which is then "spent"
   in a later commit on more visuals on machines that gained margin.

Every commit is benched A/B vs the previous round's commit (parallel-
bench `--quick` = demo1 × 2 res × 3 runs across all 6 machines), and
the bench rows ship in the same commit as the code change. Regressions
worse than -5% on any machine block the commit.

### Live feature inventory

| Feature | Cvar | Toggle | Per-machine defaults | Round commit |
|---|---|---|---|---|
| GL_FOG (linear/exp/exp2 + color + range) | `gl_fog`, `gl_fog_mode`, `gl_fog_start`, `gl_fog_end`, `gl_fog_density`, `gl_fog_red/green/blue` | autoexec | yos=OFF, others=ON linear far=2048-4096 | `c3d1de3` |
| Underwater frustum sine-warp | `gl_waterwarp` (magnitude 0..1) | autoexec | ALL=1 (one sin() per frame, only when RDF_UNDERWATER set — free) | (this round) |

(More rows landed as each round ships.)

---

- 2026-05-11 — Phase A.4/A.5 baseline benchmarks captured. `scripts/deploy.sh`
  and `scripts/bench.sh` adapted from the QuakeSpasm sister project,
  with two Q2-specific quirks documented in `bench.sh`:
  - qconsole.log lives at `~/.yq2/baseq2/` (the writable user gamedir),
    NOT next to the binary
  - resolution control needs `gl_mode -1 + gl_customwidth/customheight`
    (no `r_mode` cvar in 5.11; mode table only)
  Baseline demo1 numbers, vanilla yquake2 5.11, no optimizations:

  | Machine                      | 640×480     | 1024×768    | Notes |
  |---|---|---|---|
  | **imac-2019** (Sequoia, Radeon Pro 580X) | 709.2 fps | 701.6 fps | Polaris 20 totally unbound by GL1 fixed-function; capacity for any Phase C work |
  | **mini-g4** (Tiger, Radeon 9200 / 7447A) | 126.9 fps | 99.2 fps | Headroom king of the PPC fleet |
  | **mini-intel** (Lion, GMA 950)  |  59.4 fps* | 116.0 fps   | * Quartz vsync gates 640×480 at 60; 1024×768 doesn't match a native mode so SDL drops into a non-vsynced path |
  | **sawtooth** (Tiger, GeForce2 MX / 7400) | 95.0 fps | 82.9 fps | Real hw T&L compensates for the 500 MHz 7400 |
  | **quicksilver** (Tiger, Radeon 9000 / 7450) |  82.7 fps | 82.1 fps    | CPU-bound — same fps both resolutions |
  | **yosemite** (Panther, Rage 128 / 750)  |  18.4 fps | 14.7 fps    | Under the 20 fps floor — Phase B group-draw + multitexture cherry-picks should help; G3 confirmed as "best effort" per the risk note above |

  Phase A.1 is the minimum-deps build: WITH_CDA=no, WITH_OGG=no,
  WITH_OPENAL=no, WITH_RETEXTURING=no (sed-patched in `build.sh`;
  libjpeg isn't installed on mini-intel). Revisit retexturing in A.3
  once OpenAL/OGG/CDA dependency policy is decided. Phase A.2 (proper
  .app bundle) and demo2/demo3 grid fill are next, then Phase B.
