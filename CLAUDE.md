# yquake2 PPC port — guidance for Claude

This is a sister project to `~/quakespasm/` — same hardware fleet, same
build/deploy/bench cadence, different engine (yquake2 5.11 base instead
of QuakeSpasm).

**This file is the sticky facts. The full plan lives in `PPC_PLAN.md`.**
Read that for the 3-phase roadmap (Phase A bring-up, Phase B GL1 cherry-
picks from yquake2 latest, Phase C visual feature ports from KMQuake2).

**Read `MISTAKES.md` before lighting up an idea that smells "easy / load-
time only / zero risk".** Newest at the top. Append to it whenever a
change is reverted or a fix turns out to be wrong.

**Sister project pointer:** `~/quakespasm/` has the canonical version of
all the infrastructure (build.sh, deploy.sh, bench.sh, parallel-bench.sh,
fat-binary scheme, host-bin/qsreboot.sh, the fat SDL 1.2 framework with
Panther-compatible PPC slice, the Tiger/Panther Cocoa patches, the
cross-build host setup on mini-intel). For Q2 we adapt those — don't
re-invent. Read `~/quakespasm/CLAUDE.md` for the durable tribal knowledge
that applies equally here.

## Goal in one line

Ship the **most graphically advanced Quake II** that runs playably on
the 6-machine retro Mac fleet: G3 Panther + 3× G4 Tiger + Intel Lion +
Intel Sequoia. Same playability floors as the QuakeSpasm project (≥ 20
fps on G3, ≥ 60 fps on G4/Lion). Visual upgrades that cost 10-15% fps
are in scope as long as we stay above the floor.

**Why yquake2 5.11 specifically:**
- Last yquake2 release with native SDL 1.2 support (5.20 ported to SDL2;
  7.21 dropped SDL 1.2 entirely)
- Already has OS X support (`src/backends/sdl_osx/SDLMain.m`, targets
  10.6+ — we'll backport to 10.3/10.4 with the same patch class we
  already debugged for QuakeSpasm)
- SDL backend surface is tiny: ~3,500 LOC across 5 files. Bounded
  debug scope on Tiger/Panther.
- Renderer in `src/refresh/` is independent of the SDL backend, so
  later GL1 improvements from yquake2 latest can be cherry-picked
  without dragging in SDL2.

## Repo layout

```
~/quake2/
  yquake2/           engine source (full git history, currently at QUAKE2_5_11)
  reference/         read-only reference for cherry-picking
    yquake2-latest/  GL1 renderer cherry-picks for Phase B
    kmquake2/        visual features for Phase C (bloom, decals, fog, hi-res tex)
    fod-quake2/      Mac Cocoa launcher patterns (optional polish)
  scripts/           build/deploy/bench (adapted from ~/quakespasm/scripts)
  benchmarks/        results.csv + raw qconsole.log per run
  docs/              screenshots, design notes
  CLAUDE.md          this file
  PPC_PLAN.md        the 3-phase roadmap
  MISTAKES.md        append-only log of approaches that didn't work
  README.md          project intro
```

## Hardware fleet (same as QuakeSpasm)

| Machine | CPU | GPU | OS |
|---|---|---|---|
| **yosemite** PowerMac1,1 (1999) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther |
| **sawtooth** PowerMac3,1 (1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger |
| **quicksilver** PowerMac3,5 (2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger |
| **mini-g4** PowerMac10,1 (2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger |
| **mini-intel** Macmini2,1 (2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion |
| **imac-2019** iMac19,1 (2019) | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia |

Build targets (chip-family, not machine-identity):
- `q2-g3` → yosemite (PPC 750, 10.3.9 SDK)
- `q2-g4` → sawtooth + quicksilver + mini-g4 (PPC 7400 baseline, 10.4u SDK)
- `q2-lion` → mini-intel + imac-2019 (x86_64, native Lion toolchain)

SSH aliases + legacy crypto config: same `~/.ssh/config` as the
QuakeSpasm project. **Don't duplicate the SSH setup.** Reuse.

## yquake2 5.11 build basics

The engine builds three artifacts: `quake2` (client), `q2ded` (dedicated
server, can disable), `ref_gl.so` (GL renderer, loaded at runtime).
**The renderer is a runtime-loaded shared library on Linux/Windows,
but on macOS the build system bundles it into the .app — same end
result, different mechanics from QuakeSpasm.**

Makefile knobs at the top of `yquake2/Makefile`:
- `WITH_CDA` — CD audio. Disable (we have no CD).
- `WITH_OGG` — OGG/Vorbis music. Disable for Phase A (extra dep), revisit later.
- `WITH_OPENAL` — OpenAL. Disable for Phase A (extra dep, SDL audio is fine).
- `WITH_RETEXTURING` — hi-res TGA/JPG/PNG texture autoload. **Keep ON.**
  This is one of our main visual levers.
- `WITH_ZIP` — pak loading from zip. Keep ON (libz is in Tiger).
- `WITH_SYSTEMWIDE` — install dirs. Leave off.
- `OSX_ARCH` — defaults to `-arch i386 -arch x86_64`. We override per target.

PPC build flag override pattern (matches QuakeSpasm):
- G3:   `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4:   `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`
- Lion: `-arch x86_64 -mmacosx-version-min=10.7 -O3`

## Expected Tiger/Panther patch class

Based on the QuakeSpasm experience, expect this kind of patch in
yquake2 5.11 (which targets 10.6+):
1. **NSAlertStyle / NSAlert macros** — 10.4 only has `NSCriticalAlertStyle`.
2. **NSString encoding APIs** — `stringWithCString:encoding:` is 10.4+;
   need conditional fallback to `stringWithCString:`. (Q2 may not hit
   this — the SDLMain.m boilerplate is simpler than QuakeSpasm's
   Launcher.nib stack.)
3. **`kCGLCEMPEngine`** — 10.4.8+ only, doesn't exist in 10.3.9 SDK
   headers. Wrap in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`.
4. **gcc-4.0 vs Obj-C 2.0 dot notation** — gcc-4.0 (Panther toolchain)
   doesn't parse dot notation; need `[obj setX:y]` form.
5. **Anything else surfaced by `make` failing** — discover empirically.

The first build attempt on Lion against 10.4u SDK will surface the
full list. **Don't pre-patch speculatively.**

## SDL framework strategy: reuse QuakeSpasm's fat SDL

The fat SDL 1.2 framework at `~/quakespasm/MacOSX/SDL.framework` is
fat (x86_64 + i386 + ppc), and the PPC slice is the Panther-
compatible 10.3.9-SDK build. **Copy it into `~/quake2/MacOSX/` for
Phase A and reuse byte-for-byte.** No need to rebuild SDL; we already
solved that problem.

The Panther slice came from `~/quakespasm/MacOSX/SDL-panther.dylib`
(ppc-only, built against 10.3.9 SDK with `--disable-video-x11
--disable-altivec --disable-cdrom`). Regeneration recipe is in
`~/quakespasm/CLAUDE.md` under "How the fat SDL was built".

## Bench-and-commit cadence (carry over from QuakeSpasm)

Same discipline: smoke bench on dirty tree, commit code change, then
`scripts/bench-and-commit.sh "Phase X" --quick` on clean tree to land
the official benchmark rows. Full grid only at end-of-round. Never
wipe `benchmarks/results.csv` mid-round.

Q2's timedemo invocation differs from Q1:
- Q1: `+timedemo demo1`
- Q2: `+timedemo demo1.dm2` (the `.dm2` is required — they're separate
  files in `baseq2/demos/`)

Q2 ships three demos in `baseq2/demos/` (demo1.dm2, demo2.dm2, demo3.dm2)
matching Q1's three.

## Toggleable knobs (placeholder — populate as Phase B/C lands)

Same discipline as QuakeSpasm: every per-target visual / perf decision
must be flippable at runtime (cvar) or at launch (`-flag`). Inventory
table goes here as features land.

## Game data location

Quicksilver bench machine has the canonical game data at
`~/Desktop/Quake 2/` (after the Phase A tidy round). Mirror to other
machines via `deploy.sh` (rsync). Required dirs:
- `baseq2/pak0.pak` (184 MB — main game)
- `baseq2/pak1.pak` (13 MB — 3.20 point release)
- `baseq2/pak2.pak` (45 KB)
- `baseq2/players/` (player model skins)
- `baseq2/video/` (cinematics)
- `ctf/` (Capture the Flag mission pack — pak0 + pak1)
- *(optional)* `rogue/`, `xatrix/` — mission packs (need to source pak files)

## Do not duplicate from QuakeSpasm

- **SSH config** — already in `~/.ssh/config` with legacy crypto
- **Cross-build toolchain on mini-intel** — gcc-4.0 + 10.3.9/10.4u SDKs already installed
- **Vendored prereqs/** — Xcode 3.2.6, Xcode 2.5, SDL 1.2.15 sources live in
  `~/quakespasm/prereqs/`. ~5 GB. Don't duplicate; reference.
- **host-bin tooling** — `qsreboot.sh` already installed on every bench
  Mac. Same reboot-recovery path applies to Q2 crashes.
- **Legacy crypto SSH** — `~/.ssh/id_rsa_tiger` already wired up.

## Don't run g3 and g4 builds in parallel

Same race condition as QuakeSpasm: concurrent invocations rsync to the
same path on mini-intel and `make -j2` in the same dir. The .o files
race and the binary ends up stamped with the *other* target's CPU
subtype. Symptom: G3 binary becomes `ppc7400`, Panther loads it, then
crashes during NIB init on a 750. `scripts/build.sh` will take a flock
to serialize — don't bypass.

## Status

- 2026-05-11: project initialized. Phase A bring-up not started.
- yquake2 cloned at QUAKE2_5_11 tag (commit `033550cd`, 2013-05-20).
- Reference repos cloned for Phase B (yquake2 latest) and Phase C
  (KMQuake2 visual features, FoD Q2 Mac Cocoa patterns).
