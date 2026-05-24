# Old-Mac Quake II — six retro Macs, one fat binary

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](yquake2/LICENSE)
[![Platform: PPC + Intel macOS](https://img.shields.io/badge/Platform-PPC%20%7C%20Intel%20macOS-lightgrey.svg)](#the-fleet)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#the-fleet)
[![Engine: yquake2 5.11](https://img.shields.io/badge/Engine-yquake2%205.11-red.svg)](https://github.com/yquake2/yquake2)

<p align="center">
  <img src="docs/icon-source/quake2-icon-256.png" width="200" alt="Quake II icon" />
</p>

yquake2 5.11 port tuned to six retro Macs spanning 1999–2019. One source tree, one fat universal binary (PPC G3 + PPC G4 AltiVec + Intel x86_64) inside a single self-contained `Quake2.app` bundle. Per-machine `autoexec.cfg` ships inside the .app and is dispatched by `sysctl hw.model` at boot. Sister project of [`old-mac-quakespasm`](https://github.com/matthewdeaves/old-mac-quakespasm).

<p align="center">
  <img src="docs/screenshots/yosemite.png" width="23%" alt="yosemite (G3 Panther)" />
  <img src="docs/screenshots/quicksilver.png" width="23%" alt="quicksilver (G4 Tiger / R9000)" />
  <img src="docs/screenshots/mini-g4.png" width="23%" alt="mini-g4 (G4 Tiger / R9200)" />
  <img src="docs/screenshots/mini-intel.png" width="23%" alt="mini-intel (Lion / GMA 950)" />
</p>
<p align="center"><sub>Same binary, same content, four different GPU generations · full gallery at <a href="docs/screenshots/index.html"><code>docs/screenshots/index.html</code></a></sub></p>

## The fleet

| Machine | CPU | GPU | OS | Slice | GPU era |
|---|---|---|---|---|---|
| **yosemite** PowerMac1,1 1999 | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | `ppc_750` | fixed-function |
| **sawtooth** PowerMac3,1 1999 | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | `ppc_7400` | fixed-function |
| **quicksilver** PowerMac3,5 2001 | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | `ppc_7400` | early shader ATI |
| **mini-g4** PowerMac10,1 2005 | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | `ppc_7400` | early shader ATI |
| **mini-intel** Macmini2,1 2007 | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | `x86_64` | Intel integrated |
| **imac-2019** iMac19,1 2019 | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | `x86_64` | modern AMD discrete |

## Current build — `timedemo demo1.dm2` (median)

Live data: [`benchmarks/results.csv`](benchmarks/results.csv) · screenshots: [`docs/screenshots/index.html`](docs/screenshots/index.html) · per-machine cfgs: [`scripts/bundle/`](scripts/bundle/).

| Machine | 640×480 | 1024×768 | Floor | Visual stack |
|---|---:|---:|---:|---|
| **imac-2019** | 711.75 | 726.40 | 60 | everything maxed (GPU never bound) + 8× MSAA |
| **mini-intel** | 222.80 | 100.30 | 60 | picmip 0, trilinear, AF 8x, fog, waterwarp, group-draw, **decals 64, 2× MSAA** — **vsync default fix uncapped 640 from 60 → 223 fps** |
| **mini-g4** | 100.45 | 56.80 \** | 60 | picmip 0, trilinear, AF 16x, dlights, OBB 4, retex, fog, waterwarp, group-draw, **decals 32, 2× MSAA** |
| **sawtooth** | 72.90 | 65.45 | 60 | picmip 0, trilinear, AF 2x, `gl_flashblend 1` halos, fog, waterwarp, **decals 16** |
| **quicksilver** | 70.70 | 68.60 | 60 | picmip 0, trilinear, AF 8x, dlights, OBB 4, retex, fog, waterwarp, group-draw, **decals 32, 2× MSAA** \* |
| **yosemite** | 46.20 | 25.20 | 20 | picmip 0, trilinear, alias shadows, AF 2x, GL_FOG, waterwarp, **decals 8** |

\* quicksilver's LCD vsync caps both resolutions near 71 fps — visual features have not pushed fps below the cap, meaning there's spare GPU headroom we could spend on further effects.
\** mini-g4 1024 fps shows thermal/state degradation after many hours of continuous benching — early-session numbers on a cold machine were 120.90 / 97.50; after a cool-down the cell typically recovers. The 56.80 figure is recorded as the worst observed, not the steady-state. See MISTAKES.md.

### First build vs current — what we traded for visual upgrades

Phase A landed a near-stock yquake2 5.11 with minimal config. Today the same binary ships ~15 visual / perf cherry-picks (KMQuake2 decals + fog + waterwarp, batched group-draw, MSAA, point-sprite particles, stb_image retex, per-machine HD-pak, multitex isolation, vsync default fix, AltiVec model interp). The trade-off is below — all machines remain comfortably above their playability floor.

| Machine | Phase A 640 | Now 640 | Δ | Phase A 1024 | Now 1024 | Δ | Floor |
|---|---:|---:|---:|---:|---:|---:|---:|
| imac-2019 | 709.20 | 711.75 | +0% | 701.60 | 726.40 | +4% | 60 ✓ |
| mini-intel | 59.40 | **222.80** | **+275%** | 80.80 | 100.30 | +24% | 60 ✓ |
| mini-g4 | 126.90 | 100.45 | −21% | 99.15 | 56.80 \** | −43% | 60 ✓ |
| sawtooth | 95.00 | 72.90 | −23% | 82.90 | 65.45 | −21% | 60 ✓ |
| quicksilver | 72.40 | 70.70 | −2% | 68.50 | 68.60 | +0% | 60 ✓ |
| yosemite | 65.15 | 46.20 | −29% | 31.60 | 25.20 | −20% | 20 ✓ |

The two outliers tell the story:
- **mini-intel +275% at 640** is the vsync default fix — Apple's Quartz layer was leaving SDL's swap interval ON when the cvar was off, capping us at 60. Explicit `SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, 0)` released the cap.
- **mini-g4 −43% at 1024** is partly the visual cost and partly thermal degradation after hours of continuous benching; cool-machine numbers sit around 97 fps. Documented in [`MISTAKES.md`](MISTAKES.md).

### Phase B/C features shipped (cherry-picked from yquake2-latest + KMQuake2)

| Feature | cvar | Source | Cost on R128 |
|---|---|---|---|
| Cvar-driven linear/exp fog | `gl_fog` + range/color | KMQuake2 `r_fog.c` | -0.6 fps |
| Underwater frustum sine-warp | `gl_waterwarp` | yquake2-latest | only underwater |
| Lightmap subrect dynamic upload | `gl_lightmap_subrect` | QS port | no-op if `gl_dynamic 0` |
| Group-draw batching (`qglDrawElements`) | `gl_groupdraw` | yquake2-latest `gl1_buffer.c` | -0.75 fps |
| stb_image-based JPEG decode | — | vendored `stb_image.h` | drops libjpeg dep |
| CFBundle HD-pak search path | — | `Q2_GetBundleHDPakPath` | one-time at FS init |
| **World decals** — bullet / blood / Strogg green blood / scorch marks via BSP fragment clipping; per-machine `gl_decal_max` cap 8 (G3) → 128 (modern); textures procedurally generated, shipped in-tree at `yquake2/baseq2-extra/decals/` | `gl_decals` `gl_decal_max` | KMQuake2 `r_fragment.c` (ported renderer-side) | ~0 (gl_dynamic 0, no overdraw on empty world) |
| **MSAA** — `SDL_GL_MULTISAMPLE` wired through SDL backend; per-machine cap 0 (PPC fixed-func) → 8x (Polaris) | `gl_msaa_samples` | own port | n/a (off on R128) |

## How the binary picks its config

<p align="center">
  <img src="docs/images/architecture.svg" width="92%" alt="Architecture: Ubuntu orchestrator drives mini-intel cross-builds; deploy.sh ships one Quake2.app to all six bench machines; sysctl hw.model dispatches the per-machine autoexec at boot" />
</p>

All six per-machine cfgs ship inside `Quake2.app/Contents/Resources/`. The engine ([`yquake2/src/common/misc.c`](yquake2/src/common/misc.c) → `Q2_ExecConfigFromBundle`, called from `Qcommon_Init` after `CL_Init`) reads the one matching the host via `sysctlbyname("hw.model", ...)`. Layered after `default.cfg` → `yq2.cfg` → `config.cfg` so its cvars win.

## How it's built

<p align="center">
  <img src="docs/images/build-pipeline.svg" width="92%" alt="Build pipeline: edit on Ubuntu, rsync to mini-intel, three flock-serialised sub-builds (g3 + g4 + lion), lipo into one Mach-O universal in build/q2-fat" />
</p>

Cross-builds on mini-intel (last machine with working `gcc-4.0` + `MacOSX10.3.9.sdk` + `MacOSX10.4u.sdk`). Three flock-serialised sub-builds glued with `lipo -create` into `build/q2-fat/quake2`.

## How it's benched

<p align="center">
  <img src="docs/images/bench-loop.svg" width="92%" alt="Bench loop: ssh kills stale processes, launches quake2 with timedemo, polls qconsole.log for the result line, fetches the raw log, appends one row to results.csv tagged with the commit hash" />
</p>

```bash
scripts/build-fat.sh                              # 3-arch universal binary
scripts/deploy.sh <machine>                       # ship to one of the 6 hosts
scripts/bench.sh <machine> demo1 1024x768 3       # 3 timedemo runs, append to CSV
scripts/parallel-bench.sh                         # full matrix, all reachable legs concurrent
```

Each cell in `benchmarks/results.csv` is tagged with the commit hash that produced it.

## Run it from any folder on the Mac

Drop `Quake2.app` and a `baseq2/` directory next to each other — anywhere: `~/Applications/Games/`, `~/Desktop/Quake2/`, `/Volumes/Some Disk/Quake/`. The bundle's `SDLMain.m` chdir's to the .app's parent on Finder launch, so the engine finds `baseq2/` adjacent. No installer, no system locations, no admin.

```
<your dir>/
  Quake2.app/
    Contents/
      Info.plist
      MacOS/quake2                   (fat: ppc750 + ppc7400 + x86_64)
      MacOS/SDL.framework/           (fat: ppc + i386 + x86_64)
      Resources/Quake2.icns
      Resources/autoexec-*.cfg × 6   (per-machine, picked by sysctl)
      Resources/hd-pak/decals/       (bundled world-decal textures)
  ref_gl.so
  baseq2/
    game.so
    pak0.pak  pak1.pak  pak2.pak   ← supply your own
```

The repo does **not** distribute `.pak` files — bring your own from Steam / GOG / retail CD. Release builds with the fat .app are on the [Releases](../../releases) page.

## Repo layout

```
yquake2/         engine source (vendored at QUAKE2_5_11 tag, 033550cd)
scripts/
  build.sh           single-arch build via mini-intel
  build-fat.sh       3-arch lipo merge → build/q2-fat/
  deploy.sh          rsync fat .app to one machine
  bench.sh           one demo × resolution
  parallel-bench.sh  whole grid in parallel
  screenshot.sh      capture in-game PNGs from one host
  bundle/            Info.plist + autoexec-<machine>.cfg files (shipped inside .app)
benchmarks/      results.csv + raw qconsole.log per run
docs/
  images/        SVG architecture diagrams (rendered above)
  icon-source/   high-res icon masters (1254² source + 512/256 derivatives)
  screenshots/   per-machine in-game PNGs (demo1 + demo2) + index.html gallery
  HD_PACK.md     bundle-vs-user HD texture pack install paths
MacOSX/          fat SDL.framework (ppc + i386 + x86_64), Quake2.icns
```

| Doc | Role |
|---|---|
| `PPC_PLAN.md` | Multi-phase roadmap (A bring-up, B GL1 cherry-picks, C visual-feature ports) |
| `CLAUDE.md` | Durable tribal knowledge |
| `MISTAKES.md` | Append-only log of approaches that failed |
| `NEXT_ROUND_PLAN.md` | Forward-looking engine work (KMQuake2 decals / stencil shadows / bloom, AltiVec SIMD, MSAA, gamma) |
