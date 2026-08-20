# yquake2 PPC port — guidance for Claude

This is a sister project to `~/quakespasm/` — same hardware fleet, same
build/deploy/bench cadence, different engine (yquake2 5.11 base instead of
QuakeSpasm).

**This file is the lean sticky facts + a map to the detail docs.** Read the
linked `docs/*.md` on demand when you work in that area — don't load everything
up front. Keep this file small; when a section grows past a few lines, move it
into a topic doc and leave a pointer here.

- **Roadmap** → `PPC_PLAN.md` (3-phase plan: A bring-up, B GL1 cherry-picks, C KMQuake2 visual ports)
- **What went wrong before** → `MISTAKES.md` (newest on top). **Read it before
  lighting up an idea that smells "easy / load-time only / zero risk."** Append
  whenever a change is reverted or a fix turns out wrong.
- **Sister project** → `~/quakespasm/` has the canonical infrastructure (build/
  deploy/bench scripts, fat-binary scheme, fat SDL 1.2 framework, Tiger/Panther
  Cocoa patches, cross-build host). For Q2 we adapt those — don't re-invent. Read
  `~/quakespasm/CLAUDE.md` for durable tribal knowledge that applies here too.

## Documentation map

| Doc | Read it when… |
|---|---|
| `docs/BUILD.md` | building/deploying/packaging: build flags, Tiger/Panther patch class, SDL framework, mini-intel multi-tenancy, parallel-build hazard, deploy, **DMG pipeline + verification** |
| `docs/CONFIG.md` | touching `autoexec-*.cfg`, `misc.c` config loading, or any `gl_*` default — the 3-layer bundle config + the custom-cvar table |
| `docs/BENCH.md` | running benchmarks or smoke tests — what a smoke test MUST be, the two launch modes, timedemo specifics, fps floors |
| `docs/STATUS.md` | you need project history / the changelog (per-round narrative) |
| `docs/ICONS.md` | regenerating the app icon (`make-icon.py`) |
| `docs/WATCHLINK.md` | the `watch_host` UDP player-state feed (Apple Watch companion) — cvars, wire format, `scripts/watchlink-listen.py` |
| `docs/imac-g5-leopard-port-notes.md` | anything on the iMac G5 / Leopard / R300 |
| `docs/HD_PACK.md` | the hi-res texture pack / `stb_image` retexturing |
| `DECALS_PLAN.md`, `NEXT_ROUND_PLAN.md` | decals design / upcoming work |

## Goal in one line

Ship the **most graphically advanced Quake II** that runs playably on the
retro Mac fleet: G3 Panther + 3× G4 Tiger + G5 Leopard + Intel Lion + Intel
Sequoia. Playability floors: ≥ 20 fps on G3, ≥ ~40 fps on G4 (feature-work
floor; user pref is visuals over framerate), more where the GPU allows. Visual
upgrades that cost 10-15% fps are in scope as long as we stay above the floor.

**Why yquake2 5.11 specifically:** last release with native SDL 1.2 (5.20 went
SDL2); already has OS X support we backport to 10.3/10.4; tiny SDL backend
(~3,500 LOC); renderer in `src/refresh/` is independent of the SDL backend so
GL1 improvements cherry-pick cleanly. (Full rationale in git history / PPC_PLAN.)

**arm64 does NOT require bumping the engine.** Recorded 2026-08-20, because the
two were treated as one decision and they are not.

The coupling is narrower than "old engine, no Apple Silicon". It is: 5.11 means
SDL 1.2, and SDL 1.2 upstream never produced an arm64 build, so the shipped
`SDL.framework` has no arm64 slice. What an arm64 engine slice needs is an
**arm64 implementation of the SDL 1.2 API**, not a newer engine. `sdl12-compat`
(libsdl-org) is exactly that: the SDL 1.2 API on top of SDL2, and it is
arm64-native.

`SDL.framework` here is already fat with four slices (`x86_64 i386 ppc ppc970`),
two of them hand-built. A fifth arm64 slice built from `sdl12-compat`, carrying
the same install name, would be selected by dyld on CPU alone exactly as the
others are. PowerPC and Intel keep real SDL 1.2; only the new slice runs the
shim; the engine source does not change.

So treat these as separate decisions with separate justifications:

| Goal | What it needs | Engine bump? |
|---|---|---|
| arm64 slice | arm64 SDL 1.2 via `sdl12-compat`, and a `lipo` that can fuse arm64 | no |
| Upstream security fixes | 8.x base | yes |

The old reason for closing arm64 (`docs/STATUS.md:315-316`, "matching the sister
ports") has expired: the Half-Life port now ships a five-slice fat including
`arm64`, so matching the sister ports would today argue FOR it.

**Also re-check before quoting `NEXT_ROUND_PLAN.md:246-248`** ("SDL2 base bump,
hard pass, loses Panther + Tiger"). That ruling rests on
`docs/imac-g5-leopard-port-notes.md`, which names only `leopard-sdl2` (2.0.6,
Leopard 10.5+). It does not mention `panther-sdl2` (2.0.3, targeting 10.3 and
10.4), which the Half-Life port links statically into its PowerPC slices and
which runs on the G3. The ruling may still be right, but its stated evidence is
incomplete.

## Repo layout

```
~/quake2/
  yquake2/           engine source (full git history, currently at QUAKE2_5_11)
  reference/         read-only reference for cherry-picking
    yquake2-latest/  GL1 renderer cherry-picks for Phase B
    kmquake2/        visual features for Phase C (bloom, decals, fog, hi-res tex)
    fod-quake2/      Mac Cocoa launcher patterns (optional polish)
  scripts/           build/deploy/bench + bundle/ autoexec cfgs
  benchmarks/        results.csv + raw qconsole.log per run
  docs/              the topic docs above (BUILD/CONFIG/BENCH/STATUS/ICONS/…)
  CLAUDE.md          this file — lean sticky facts + doc map
  PPC_PLAN.md        the 3-phase roadmap
  MISTAKES.md        append-only log of approaches that didn't work
  README.md          project intro
```

## Hardware fleet (same as QuakeSpasm)

| Machine | CPU | GPU | OS |
|---|---|---|---|
| **yosemite** PowerMac1,1 (1999) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther |
| **yosemite-tiger** — the SAME Mac, 2nd partition | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.4.11 Tiger |
| **sawtooth** PowerMac3,1 (1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger |
| **quicksilver** PowerMac3,5 (2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger |
| **mini-g4** PowerMac10,1 (2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger |
| **imac-g5** PowerMac8,2 (2004, 17" ALS) | 2.0 GHz PPC 970FX | ATI Radeon 9600 (RV351) 128 MB | 10.5.8 Leopard, native 1440×900 |
| **mini-intel** Macmini2,1 (2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion |
| **imac-2019** iMac19,1 (2019) | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia |

SSH aliases + legacy crypto: same `~/.ssh/config` as QuakeSpasm. There are
**TWO interchangeable Intel cross-build minis** (gcc-4.0 + 10.3.9/10.4u/10.5
SDKs): **mini-intel** (10.188.1.190) and **mini-intel2** (10.188.1.216) — same
Macmini2,1 / 10.7.5 / identical toolchain, so either can build any slice.
`build.sh` / `build-fat.sh` no longer hardcode a host: they call
`scripts/pick-build-host.sh --acquire` to take one that is reachable and idle,
and release it on exit. So Q2 and the QuakeSpasm/Q3/Half-Life sister projects
can now build **at the same time on different minis**. `BUILD_HOST=<alias>`
pins one; `scripts/pick-build-host.sh --status` shows both.

**Why the claim lives on the mini, not in the repo:** a per-checkout `flock`
cannot see a build another repo (or another Claude) started on the same box.
The picker locks `/tmp/.retro-build-lock` ON the host and also counts running
compiler processes as busy, so it detects builds started outside it entirely.

**Reuse, don't duplicate** — SSH config, toolchain, vendored prereqs, host-bin
tooling all live on the QuakeSpasm side (details in `docs/BUILD.md`).

`yosemite` and `yosemite-tiger` are **one machine on one IP** with two OS
partitions — only one is booted at a time. Switch with
`ssh yosemite 'sudo bless --mount "/Volumes/<vol>" --setBoot'` then reboot
(`scripts/host-bin/qsreboot.sh` on the QuakeSpasm side, or plain
`sudo /sbin/reboot </dev/null` — **not** `sudo -n`, which Tiger's and Panther's
sudo 1.6.x reject outright). `parallel-bench.sh` refuses to run both legs.

Build targets (chip-family, not machine-identity):
- `q2-g3` → yosemite (PPC 750, 10.3.9 SDK, min 10.3)
- `q2-g4` → sawtooth + quicksilver + mini-g4 (PPC 7400 baseline, **10.3.9 SDK,
  min 10.3** — see rule 6 below; needs `-faltivec` + an explicit `-isystem` for
  gcc's own `altivec.h`)
- `q2-g5` → imac-g5 (PPC 970FX, 10.5 SDK, `-mcpu=970 -maltivec`; stamps a
  distinct `ppc970` Mach-O subtype so dyld prefers it on a G5)
- `q2-lion` → mini-intel + imac-2019 (x86_64, native Lion toolchain, **min 10.6**)

## Critical rules — read before you act

1. **iMac G5 / Leopard / R300 hazard.** The Radeon 9600 Leopard driver
   **hard-hangs the entire OS** on a non-native fullscreen mode *switch* (grey
   screen, no SSH, needs the power button). Mitigations are in place
   (`vid_desktopfullscreen` same-mode capture; `GLimp_ForceDesktopFullscreen()`;
   `bench.sh` refuses non-native fullscreen on `imac-g5`) — **never bypass them
   or trigger a remote non-native mode switch on the G5.** Detail:
   `docs/imac-g5-leopard-port-notes.md` + `MISTAKES.md`.
2. **Don't run PPC builds (g3/g4/g5) in parallel on the SAME mini.** They rsync
   to the same `quake2/` dir there and race `.o` files → wrong CPU-subtype stamp
   → crash. `build.sh` flocks; `build-fat.sh` runs g3→g4→g5→lion sequentially and
   now pins ONE claimed host for the whole run. (Two builds on *different* minis
   are fine — that is the point of the second box.) Detail: `docs/BUILD.md`.
3. **A smoke test is a demo run that auto-exits** (`bench.sh … demo1 … 1` or
   `smoke-dmg.sh`) — NEVER `+map` (grabs the display forever) or engine-load-only.
   A clean demo does NOT clear a *gameplay* crash; also test "start a new game"
   for in-game regressions. Always `killall -TERM` before `-KILL`. Detail:
   `docs/BENCH.md`.
4. **Ship a verified DMG, built on Tiger (not the G3).** `make-dmg.sh` verifies
   the binaries inside the finished image are byte-identical to source (a single
   flipped byte once shipped an illegal-instruction crash to every G4). Test the
   real artifact with `deploy-dmg.sh` + `smoke-dmg.sh`, then re-verify the
   published GitHub asset. Detail: `docs/BUILD.md` + `MISTAKES.md`.
5. **Bundle config is applied BEFORE `CL_Init`/`VID_Init`** (in `misc.c`) so the
   renderer comes up in the final mode with no refresh-DLL reload — applying it
   later hard-crashed the Rage128/Panther G3. Cfgs use `set CVAR VALUE` and ship
   comment-stripped. Detail: `docs/CONFIG.md`.
6. **Every PPC slice carries its exact cpusubtype — never a generic `ppc (ALL)`.**
   dyld and the kernel grade fat members by CPU subtype *alone*; the OS floor
   plays no part. A generic `ppc` member matches every PowerPC host, so a fat of
   `[ppc ALL, ppc7400, ppc970]` mis-grades on a G3 under Tiger/Leopard and the
   binary **refuses to exec** (proven on hardware in the sister Half-Life port;
   Panther's laxer 2003 dyld accepts it, which is what makes this easy to ship
   unnoticed). `-mcpu=` normally stamps the subtype, but **`-faltivec` silently
   defeats it** — which is exactly what the min-10.3 g4 slice needs. `build.sh`
   therefore asserts the subtype on all four artifacts after every PPC build and
   re-stamps the Mach-O header when it drifted. **Never remove that block, and
   never assume the compiler got it right.** `make-dmg.sh` re-checks with
   `lipo -archs`. Note `file` prints subtype 9 as `ppc_650` on a modern host —
   a naming quirk, not a bad stamp; trust `lipo`.

## Hard rule — building and compiling: verify, never assume

An exit code of 0 is not evidence that the thing you wanted got built. Every
one of these has actually bitten this project or its sister ports:

- **Never trust "done" or a zero exit.** Check the artifact itself: `lipo -archs`
  / `lipo -info` for slices, `otool -L` for what it links, `otool -h` for the
  header. If you claim a build has a property, show the command that proves it.
- **Stale binaries are the trap.** A failed build leaves the PREVIOUS run's
  output in place, and every downstream check then passes on a file nobody meant
  to ship. `build.sh` now `rm -rf`s `build/q2-$TARGET` before fetching, and runs
  `make clean` on the build host — keep both.
- **Rebuild the whole fat when in doubt.** `build/q2-fat` must come from one
  `build-fat.sh` run. If you rebuild a single slice afterwards, the per-target
  dir and the fat's member are no longer the same file. Prove they agree:
  `lipo -thin <arch> build/q2-fat/quake2 -output /tmp/m && md5sum /tmp/m build/q2-<t>/quake2`.
- **The PPC builds are NOT byte-reproducible** (~138 bytes differ between two
  builds of identical source — embedded build metadata). So an md5 mismatch
  across two separate build runs proves nothing; only compare artifacts from
  the SAME run.
- **Bump the version for every build that leaves this machine**, so what got
  deployed is identifiable from Finder's Get Info, not just the console.
  `deploy.sh` and `make-dmg.sh` stamp `CFBundleShortVersionString` /
  `CFBundleVersion` from `git describe` (the static plist's `5.11` is upstream's
  engine version and never changes).
- **Verify what actually landed on the target**, not what you sent — `deploy.sh`
  md5s the deployed binary against source, and `make-dmg.sh` mounts the finished
  image and hashes the binaries inside it.

## Hard rule — releases

Fact-check the docs before tagging, every time: README (including the per-CPU
OS floors and the framerate table), the in-DMG `README.txt`, and the SVG
diagrams — those name SDKs and `-mmacosx-version-min` values and go stale
silently. State plainly which configurations are **built but untested** rather
than implying they are supported. The GitHub release needs real notes describing
what changed and what was measured, and the attached DMG must be the verified
one.

## Status

Current: **v2.5.0** (per-weapon blast marks on walls — rockets/grenades/plasma/
BFG/railgun all leave distinct decals on the surface they actually hit, not just
the floor; four new procedural TGAs; crisp stencil shadows enabled on the full
G4 fleet after re-bench showed the old 60% cost cliff is gone post-AltiVec;
deploy fix preserving player models through rsync). v2.5.1 added sawtooth
(GF2 MX) to the stencil-shadow set — A/B benched ~19% cost, above floor — so
the whole PPC fleet now has crisp shadows. Full per-round history is in
**`docs/STATUS.md`**. Next: bloom redo (dedicated render-target, sub-res budget);
AltiVec `R_BuildLightMap`; GL1 gamma correction.
