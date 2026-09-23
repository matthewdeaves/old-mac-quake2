# Quake II: old-Mac port

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](yquake2/LICENSE)
[![Platform: PPC + Intel + Apple Silicon macOS](https://img.shields.io/badge/Platform-PPC%20%7C%20Intel%20%7C%20Apple%20Silicon-lightgrey.svg)](#tested-machines)
[![macOS: 10.3.9 → 26](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2026-success.svg)](#tested-machines)
[![Engine: yquake2 5.11](https://img.shields.io/badge/Engine-yquake2%205.11-red.svg)](https://github.com/yquake2/yquake2)

<p align="center">
  <img src="docs/icon-source/quake2-icon-256.png" width="180" alt="Quake II icon" />
</p>

A Quake II port (yquake2 5.11) built as one six-slice fat PowerPC + Intel + Apple
Silicon binary inside a single `Quake2.app`, tested on a range of old Macs, G3,
G4, G5 and Intel, from a 1999 Power Mac to a 2019 iMac. The app carries three config layers: shared
controls, a per-arch baseline picked by the running slice, and a per-machine
overlay picked at boot by `sysctl hw.model`. A headless Linux dedicated server
builds from the same tree (see [`server/`](server/README.md)).

> **About this project.** A personal project, I love Quake and I collect and
> tinker with old Macs. My part is the setup and testing: the build, deploy and
> benchmark scripts, and the per-machine settings. The engine and config changes
> were made mostly **with AI (Claude), which I directed and checked against real
> benchmarks on the machines**. The visual features are ported from KMQuake2 and
> yquake2, not written from scratch.

<p align="center">
  <img src="docs/screenshots/yosemite.png" width="19%" alt="yosemite (G3 Panther)" />
  <img src="docs/screenshots/sawtooth.png" width="19%" alt="sawtooth (G4 Tiger / GF2 MX)" />
  <img src="docs/screenshots/quicksilver.png" width="19%" alt="quicksilver (G4 Tiger / R9000)" />
  <img src="docs/screenshots/mini-g4.png" width="19%" alt="mini-g4 (G4 Tiger / R9200)" />
  <img src="docs/screenshots/mini-intel.png" width="19%" alt="mini-intel (Lion / GMA 950)" />
</p>
<p align="center"><sub>Same fat binary, same demo, five legacy GPU generations · 1999 → 2007; native arm64 support included</sub></p>

## Tested machines

| Mac | CPU / GPU | OS tested | Slice |
|---|---|---|---|
| **yosemite** PowerMac1,1 | 449 MHz G3 / Rage 128 | 10.3.9, 10.4.11 | `ppc750` |
| **mini-g4** PowerMac10,1 | 1.25 GHz G4 / Radeon 9200 | 10.4.11 | `ppc7400` |
| **sawtooth**, **quicksilver** | G4 / GeForce2 MX, Radeon 9000 | 10.4.11 (earlier releases) | `ppc7400` |
| **G5 tower** PowerMac7,3 | dual 2.7 GHz G5 / Radeon 9600 | 10.3.9, 10.4.11, 10.5.8 | `ppc970` |
| **imac-g5** PowerMac8,2 | 2.0 GHz G5 / Radeon 9600 | 10.5.8 | `ppc970` |
| **mini-sl** Macmini3,1 | Core 2 Duo / GeForce 9400M | 10.6.8 | `x86_64` |
| **mini-intel**, **mini-intel2** Macmini2,1 | Core 2 Duo / GMA 950 | 10.7.5 | `x86_64` |
| **imac-2019** iMac19,1 | i5-9600K / Radeon Pro 580X | 15.7 | `x86_64` |
| **Apple M5** MacBook Air | Apple M5 | 26 | `arm64` |

`dyld` picks a slice by CPU alone. Every PowerPC slice is built for 10.3.9, so
G3, G4 and G5 all run Panther through Leopard; a G4 on Panther is untested.
`x86_64` needs 10.6, and `arm64` needs 11. The 32-bit Intel slice (`i386`, Core
Duo/Solo, 10.4+) has never been run on hardware. Apple Silicon uses
`sdl12-compat` over a bundled SDL 2.32.4; every other slice uses real SDL 1.2
(`docs/adr/0015`).

## Framerate

`timedemo`, each Mac's shipped settings (all its effects on), vsync off. Live
numbers are in [`benchmarks/results.csv`](benchmarks/results.csv).

| Class | Resolution | fps |
|---|---|---:|
| G3 / Rage 128 (Panther) | 1024×768 | 28.4 (demo2) |
| G4 / Radeon 9200 | 1024×768 | 55.7 |
| G5 / Radeon 9600 | 1680×1050 | 50.2 |
| Core 2 Duo / GeForce 9400M | 1920×1080 | 44.9 (demo2) |
| Core 2 Duo / GMA 950 | 1024×768 | 58.8 |
| Radeon Pro 580X, 8x MSAA | 2560×1440 | 176 |
| Apple M5, 4x MSAA | 1920×1080 | 264.6 |

The floors are 20 fps on a G3 and about 40 on a G4. Above them, frame rate is
spent on effects. Sawtooth and quicksilver were off this cycle.

## How it's built and benchmarked

One modern Mac drives the whole fleet over SSH. The Lion mini does double duty:
it cross-builds the five PowerPC and Intel slices; `arm64` builds on the orchestration Mac. These diagrams
cover the setup, the build pipeline and the timedemo bench loop.

![Build and bench rack: one orchestration Mac drives the fleet via the Lion mini cross-build host](docs/images/architecture.svg)

![Build pipeline: six slices (ppc750, ppc7400, ppc970, i386, x86_64, arm64) lipo'd into one fat binary](docs/images/build-pipeline.svg)

![Bench loop: the orchestration Mac launches a timedemo over SSH, reads qconsole.log back, and the median lands in results.csv](docs/images/bench-loop.svg)

## Features

- **One six-slice fat binary** (`ppc750`, `ppc7400`, `ppc970`, `i386`, `x86_64`,
  `arm64`) in a self-contained `Quake2.app`; runs natively from Mac OS X 10.3.9
  Panther through modern Apple Silicon macOS.
- **Native Apple Silicon support** through the `arm64` slice and bundled
  `sdl12-compat`/SDL2 runtime, with bloom and MSAA on.
- **Three config layers baked into the `.app`**, shared controls, a per-arch
  baseline picked by the running slice, and a per-machine overlay dispatched at
  boot by `sysctl hw.model` (all applied before video init, so the renderer
  comes up in its final mode). Every visual knob is a runtime cvar.
- **GL1 renderer cherry-picks + KMQuake2 visual features**, cvar-driven fog,
  underwater warp, group-draw batching, MSAA, energy-shell glow, lightmapped
  glass/grates, water caustics, extended draw distance.
- **World decals + per-weapon blast marks**, rocket, grenade, plasma, BFG and
  railgun each leave a distinct mark on the surface they actually hit (ported
  from KMQuake2's fragment clipper; `gl_decals`).
- **Stencil shadows on every PowerPC machine**, with a soft blob fallback where
  the GPU can't afford them.
- **Native-res desktop fullscreen**, same-mode display capture; hardwired on
  the iMac G5 where a mode switch hangs the Leopard driver.
- Optional **Apple Watch "tactical computer" companion** (`watchlink`), streams
  live health / armor / ammo / inventory / objectives to an iPhone + Watch over
  Bonjour; off by default. Companion app:
  [quake2-tactical-watch](https://github.com/matthewdeaves/quake2-tactical-watch).

## Get the latest release

Download the latest disk image from
[**Releases**](https://github.com/matthewdeaves/old-mac-quake2/releases/latest)
(`Quake2-OldMac-<version>.dmg`), one image runs on Mac OS X 10.3.9 Panther,
Tiger, Leopard, Lion and modern macOS.

1. Mount the `.dmg` and copy `Quake2.app`, `ref_gl.so`, `q2ded` and the `baseq2/`
   folder into `/Applications/Quake2/`.
2. **Add your retail data**, drop your own `pak0.pak`, `pak1.pak`, `pak2.pak`
   into `baseq2/`, and copy the whole `players/` folder from your retail
   `baseq2/` (models/skins, without it multiplayer models render invisible).
   Retail Quake II is on Steam and GOG; the shareware `pak0.pak` also works.
3. Double-click `Quake2.app`. It auto-detects the machine, applies the tuned
   config and opens fullscreen. On modern macOS, clear Gatekeeper with
   `xattr -dr com.apple.quarantine Quake2.app` (not needed on Panther/Tiger/Lion).

## Dedicated server

Building and running the Linux server yourself: [`server/README.md`](server/README.md).

The servers this project actually runs (hosting, deployment, monitoring) are
managed in a separate repo,
[**retro-server-infra**](https://github.com/matthewdeaves/retro-server-infra),
not in this one.

## Sister projects

Same machines, same tooling, other id engines:
[**old-mac-quakespasm**](https://github.com/matthewdeaves/old-mac-quakespasm)
(Quake) and [**old-mac-quake3**](https://github.com/matthewdeaves/old-mac-quake3)
(Quake III Arena).

### Why `/Applications` on modern macOS

macOS asks for permission, every launch, before an app it cannot identify reads
Desktop, Documents or Downloads. A game in `/Applications` never triggers that
prompt. Keep the `.app` and its game data together there. Macs on 10.3 to 10.7
don't have this restriction.

## Credits & licence

Built on [yquake2](https://github.com/yquake2/yquake2) and id Software's Quake II
engine. GPLv2 (see [`yquake2/LICENSE`](yquake2/LICENSE)). Game data (`baseq2`
paks) is **not** included, bring your own from Steam / GOG / retail CD.
