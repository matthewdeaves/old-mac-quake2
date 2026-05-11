# Old-Mac Quake II — six retro Macs, one fat binary

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](yquake2/LICENSE)
[![Platform: PPC + Intel macOS](https://img.shields.io/badge/Platform-PPC%20%7C%20Intel%20macOS-lightgrey.svg)](#the-fleet)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#the-fleet)
[![Engine: yquake2 5.11](https://img.shields.io/badge/Engine-yquake2%205.11-red.svg)](https://github.com/yquake2/yquake2)

<p align="center">
  <img src="docs/screenshots/icon.png" width="128" alt="Quake II icon" />
</p>

A yquake2 5.11 port tuned to run on **six retro Macs spanning 1999–2019**. One source tree, one fat universal binary (PPC G3 + PPC G4 AltiVec + Intel x86_64) inside a single self-contained `Quake2.app` bundle, with per-machine `autoexec.cfg` shipped inside the .app and dispatched by `sysctl hw.model` at boot. Sister project of [`old-mac-quakespasm`](https://github.com/matthewdeaves/old-mac-quakespasm).

> **Status:** this is an early-stage build. The fleet is benching cleanly with a per-machine cfg layer, but no engine-level optimisation rounds have landed yet — Phase B GL1 cherry-picks (water warp, multitexturing, group draw call, dlight optimisation) are still ahead. Treat the numbers below as the starting line, not the ceiling.

## The fleet

| Machine | CPU | GPU | OS | Slice |
|---|---|---|---|---|
| **yosemite** (PowerMac1,1, 1999) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | `ppc_750` |
| **sawtooth** (PowerMac3,1, 1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | `ppc_7400` |
| **quicksilver** (PowerMac3,5, 2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | `ppc_7400` |
| **mini-g4** (PowerMac10,1, 2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | `ppc_7400` |
| **mini-intel** (Macmini2,1, 2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | `x86_64` |
| **imac-2019** (iMac19,1, 2019) | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | `x86_64` |

dyld picks the right slice per host. Four GPU eras: fixed-function (Rage 128, GeForce2 MX), early shader-era ATI (Radeon 9000 / 9200), Intel integrated (GMA 950), modern AMD discrete (Pro 580X).

## Phase A baseline — demo1, fat binary, per-machine autoexec

`timedemo demo1.dm2`, median of run 2 + run 3 (drops the cold first run). Each machine's `autoexec-<machine>.cfg` is loaded by the engine via CFBundle at boot — see [`scripts/bundle/README.md`](scripts/bundle/README.md) for the per-machine cvar choices. Live data: [`benchmarks/results.csv`](benchmarks/results.csv).

| Machine | 640×480 | 1024×768 |
|---|---:|---:|
| **mini-g4** (Radeon 9200 / PPC 7447A 1.25 GHz) | 126.9 | 99.15 |
| **sawtooth** (GeForce2 MX / PPC 7400 500 MHz) | 95.0 | 82.9 |
| **mini-intel** (GMA 950 / Core 2 Duo 2.33 GHz) | 59.4 \* | 80.8 |
| **quicksilver** (Radeon 9000 / PPC 7450 733 MHz) | 72.4 | 68.5 |
| **yosemite** (Rage 128 / PPC 750 449 MHz) | 65.15 | 31.6 |
| imac-2019 (Pro 580X / i5-9600K 3.7 GHz) | not yet benched | not yet benched |

\* Lion's Quartz vsync caps 640×480 at 60 fps; 1024×768 doesn't match a native panel mode and escapes the cap.

Three observations from the per-machine autoexec round:
- **Sawtooth (GeForce2 MX) went 14 → 95 fps at 640×480** vs the unconfigured baseline. The autoexec disables `gl_dynamic`, drops `gl_picmip` to 1, and disables retexturing — the GeForce2 MX is submission-overhead bound and benefits enormously from fewer GL calls.
- **Yosemite went 14 → 31 fps at 1024×768** — same recipe, same kind of GPU. Now comfortably above the 20 fps "playable" floor at 1024 and 60+ fps at 640.
- **Quicksilver and mini-g4 lost a little fps** because their autoexec turns quality *up* (4× AF, trilinear, retexturing, dlights) — they had plenty of GPU headroom (both CPU-bound near 80–127 fps).

In-game screenshots are intentionally not in this README yet — the Q2 TGA writer has a colour/orientation bug that needs sorting before we ship visual proofs.

## How the binary picks its config

<p align="center">
  <img src="docs/images/architecture.svg" width="92%" alt="Architecture: Ubuntu orchestrator drives mini-intel cross-builds; deploy.sh ships one Quake2.app to all six bench machines; sysctl hw.model dispatches the per-machine autoexec at boot" />
</p>

All six per-machine cfgs ship inside `Quake2.app/Contents/Resources/`. The engine ([`yquake2/src/common/misc.c`](yquake2/src/common/misc.c) → `Q2_ExecConfigFromBundle`) reads the one matching the host via `sysctlbyname("hw.model", ...)`, layered AFTER the standard `default.cfg` → `yq2.cfg` → `config.cfg` chain so its cvars win. The .app is then a drop-in distribution unit — end users only need it plus their own `baseq2/pak*.pak` next to it.

The fat binary's per-arch dispatch is handled by macOS dyld — same Mach-O, different slice per host CPU. Per-machine tuning is layered on top via the runtime sysctl lookup.

## How it's built

<p align="center">
  <img src="docs/images/build-pipeline.svg" width="92%" alt="Build pipeline: edit on Ubuntu, rsync to mini-intel, three flock-serialised sub-builds (g3 + g4 + lion), lipo into one Mach-O universal in build/q2-fat" />
</p>

Cross-builds run on the Mac mini Intel — the last machine with a working `gcc-4.0` + `MacOSX10.3.9.sdk` + `MacOSX10.4u.sdk` toolchain (Xcode 3.2.6 era). Three sub-builds (G3 with 10.3.9 SDK, G4 with 10.4u SDK + `-maltivec`, Intel with Lion default SDK), glued with `lipo -create` into one fat `build/q2-fat/quake2`. The `.app` bundle ships identically to all six machines.

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

Every phase that lands gets a smoke bench (demo1 × 2 res × 3 runs) committed alongside the code change. CSV in [`benchmarks/results.csv`](benchmarks/results.csv) is a rolling history — every cell tagged with the commit hash that produced it.

## Run it from any Quake 2 folder

The bundle is self-contained and location-independent: `Quake2.app` ships with the engine binary, `SDL.framework`, the icon, and all six per-machine autoexec cfgs inside `Contents/Resources/`. `ref_gl.so` + `baseq2/` live alongside in the same parent dir. Move that whole parent dir anywhere on the Mac — `/Applications/Games/`, `~/Documents/`, `/Volumes/External/` — and double-click `Quake2.app` to launch.

```
<your dir>/
  Quake2.app/
    Contents/
      Info.plist
      MacOS/quake2                   (fat: ppc750 + ppc7400 + x86_64)
      MacOS/SDL.framework/           (fat: ppc + i386 + x86_64)
      Resources/Quake2.icns
      Resources/autoexec-*.cfg × 6   (the per-machine tuning, picked by sysctl)
  ref_gl.so
  baseq2/
    game.so
    pak0.pak  pak1.pak  pak2.pak
```

The repository does **not** distribute the `.pak` files — those are from your retail Quake II install (Steam, GOG, or original CD). Drop them into `baseq2/` next to the deploy.

## Repo layout

```
yquake2/         engine source (vendored at QUAKE2_5_11 tag, 033550cd)
scripts/
  build.sh           single-arch build via mini-intel
  build-fat.sh       3-arch lipo merge → build/q2-fat/
  deploy.sh          rsync fat .app to one machine (only deploy mode)
  bench.sh           one demo × resolution
  parallel-bench.sh  whole grid in parallel
  screenshot.sh      capture in-game PNGs from one host (currently has a TGA writer bug)
  bundle/            Info.plist + autoexec-<machine>.cfg files (shipped inside .app)
benchmarks/      results.csv + raw qconsole.log per run
docs/
  images/        SVG architecture diagrams (rendered above)
MacOSX/          fat SDL.framework (ppc + i386 + x86_64), Quake2.icns
```

`PPC_PLAN.md` is the multi-phase roadmap. `CLAUDE.md` is the durable tribal knowledge file. `MISTAKES.md` is the append-only log of things that didn't work, so we don't re-litigate them later.

## Status

**Phase A (baseline + per-machine autoexec):** done. Fleet benches cleanly; bundle is self-contained.

**Next:** Phase B GL1 cherry-picks from yquake2 latest (water warp, multitexturing, group draw call, dlight optimisation). The Rage 128 on yosemite is GL-submission-overhead bound, so group draw + multitex are expected to be the big wins there.
