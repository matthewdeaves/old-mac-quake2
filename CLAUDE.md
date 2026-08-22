# Quake II old-Mac port

Quake II on yquake2 5.11 as ONE fat PowerPC + Intel app, from a single
`Quake2.app`, plus a Linux dedicated server from the same tree. Sticky facts
only, loaded every session. Reasoning and rejected alternatives live in
`docs/adr/`; settled negatives live in `MISTAKES.md`.

Sister project `~/quakespasm/` owns the shared infrastructure (SSH config,
toolchain, vendored prerequisites, the fat SDL framework, host tooling). **Reuse
it, do not re-invent it.**

## Commands

```sh
scripts/pick-build-host.sh --status              # which Intel mini is free
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo, one pinned host
scripts/build.sh <g3|g4|g5|lion>                 # one slice, for fast iteration only
scripts/deploy.sh <machine>                      # ships build/q2-fat
scripts/make-dmg.sh                              # → dist/, hdiutil step on a TIGER box
scripts/deploy-dmg.sh <machine>                  # install from the image, as a human does
scripts/smoke-dmg.sh <machine>                   # production-config launch test
scripts/bench.sh <machine> <demo> <WxH> [runs]
scripts/build-server-linux.sh [--arch aarch64]   # Linux q2ded, in a Debian 11 container
```

`BUILD_HOST=` pins a mini, `DMG_HOST=` the packaging box.

## Facts

- **Six slices, graded by CPU subtype alone.** `ppc750` (G3, min 10.3),
  `ppc7400` (all G4s, min 10.3), `ppc970` (G5, min **10.5**, a real floor),
  `x86_64` (min 10.6), `i386` (min 10.4, never tested on hardware), `arm64`
  (min 11.0, optional: without it the fat is five). The OS plays no part in
  dyld's choice, so a machine gets its slice whether or not it can run it.
  `docs/adr/0001`, `0014`, `0015`
- **`-faltivec` silently defeats `-mcpu=7400`'s cpusubtype stamping**, and a
  generic `ppc (ALL)` member in the fat makes the binary refuse to exec on a G3
  under Tiger or Leopard while Panther accepts it. `build.sh` asserts and
  re-stamps all four artifacts after every PPC build. **Never remove that
  block.** `file` printing `ppc_650` for subtype 9 is a tool quirk; trust
  `lipo`. `docs/adr/0001`
- **The engine is pinned at yquake2 `QUAKE2_5_11`, commit `033550cd`, and that
  means SDL 1.2.** This tree has **ONE renderer**, `src/refresh/` building
  `ref_gl.so`. There is no gl1/gl3 split and no renderer-selection cvar; that is
  upstream only. Any doc claiming otherwise is describing upstream, not this
  tree. `docs/adr/0002`
- **The `arm64` slice is the odd one out twice.** It builds at `-O2` where every
  other slice is `-O3` (`build-arm64.sh:138`), and it is the only slice whose
  `SDL.framework` member is **sdl12-compat**, which `dlopen`s the bundled
  `libSDL2-2.0.0.dylib` at runtime. It still links the same
  `@executable_path/SDL.framework/...` install name as the other five, and it
  does **not** link SDL2 directly. `docs/adr/0014`, `0015`
- **Five slices cross-compile on an Intel Lion mini** (`mini-intel` or
  `mini-intel2`, interchangeable); `arm64` cannot, and is built on the
  orchestration Mac by `scripts/build-arm64.sh`. Ask
  `scripts/pick-build-host.sh`, never hardcode: the claim is a lock ON the
  host, so it sees builds other repos and agents started. `docs/adr/0005`
- **Never run two PPC builds on the same mini.** They share one `-arch ppc`
  object tree and race the `.o` files into the wrong CPU-subtype stamp. Two
  builds on different minis are the point of the second box. `docs/adr/0005`
- **Build the release DMG on a Tiger G4, never Lion and never the G3.** Lion's
  `hdiutil` cannot write a Panther-mountable image and no flag fixes it; the
  1999 G3 once flipped a byte and shipped an illegal-instruction crash to every
  G4. `docs/adr/0005`
- **Never trust "done" or exit 0.** `hdiutil verify` is not a content check.
  Verify the property on the artifact (`lipo -archs`, `otool -L`, `otool -h`),
  and md5 the bytes at the last hop the user runs. PPC builds are **not**
  byte-reproducible (~138 bytes of metadata), so only compare artifacts from the
  same run. `docs/adr/0006`
- **Bundle config is three layers applied BEFORE `CL_Init`/`VID_Init`** (shared
  controls, per-arch baseline picked at compile time, per-machine overlay picked
  by `hw.model`). Applying it later escalates into a refresh-DLL reload that
  hard-crashes the Rage 128 G3. Cfgs use `set CVAR VALUE` and ship
  comment-stripped. `docs/adr/0007`
- **iMac G5 hazard: the Radeon 9600 Leopard driver hard-hangs the whole OS on a
  non-native fullscreen mode SWITCH**, grey screen, no SSH, physical power
  button only. Three guards are in place (`vid_desktopfullscreen`,
  `GLimp_ForceDesktopFullscreen()`, `bench.sh` refusing). **Never bypass them or
  trigger a remote non-native mode switch on the G5.** `docs/adr/0008`
- **A smoke test is a demo run that auto-exits.** Never `+map`, which grabs the
  display forever, and never an engine-load-only check. A clean demo does not
  clear a *gameplay* crash: also start a new game, on **base1**. Always
  `killall -TERM` before `-KILL`. `docs/adr/0009`
- **Playability floors: G3 ≥ 20 fps, G4 ≥ ~40 fps** (was 60; the user preference
  is visuals over framerate). Above the floor, prefer a visual feature to
  framerate nobody needs. `docs/adr/0009`
- **Every per-machine default is an A/B on that machine**, never inferred from
  GPU class. `docs/adr/0010`
- **We ship code and generated art, never game content.** `docs/adr/0012`

## Machines

| Machine | CPU | GPU | OS | Slice |
|---|---|---|---|---|
| **yosemite** PowerMac1,1 | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | `ppc750` |
| **yosemite-tiger** same Mac, 2nd partition | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.4.11 Tiger | `ppc750` |
| **sawtooth** PowerMac3,1 | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | `ppc7400` |
| **quicksilver** PowerMac3,5 | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | `ppc7400` |
| **mini-g4** PowerMac10,1 | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | `ppc7400` |
| **imac-g5** PowerMac8,2 | 2.0 GHz PPC 970FX | ATI Radeon 9600 128 MB | 10.5.8 Leopard, native 1440x900 | `ppc970` |
| **mini-intel** Macmini2,1 | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | `x86_64` |
| **imac-2019** iMac19,1 | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | `x86_64` |

Two build minis: `mini-intel` (10.188.1.190) and `mini-intel2`
(10.188.1.164), same Macmini2,1 / 10.7.5 / identical toolchain.

`yosemite` and `yosemite-tiger` are **one machine on one IP** with two OS
partitions; only one is booted at a time. Switch with
`ssh yosemite 'sudo bless --mount "/Volumes/<vol>" --setBoot'` then plain
`sudo /sbin/reboot </dev/null`, **not** `sudo -n`, which Tiger's and Panther's
sudo 1.6.x reject outright. `parallel-bench.sh` refuses to run both legs.

## Working alongside the other repos

Five repos are worked on together: the four game ports and the private
`retro-server-infra`, which runs the servers those ports build. A session may be
open in each at once. Three rules keep them out of each other's way.

**Hardware is claimed, never assumed free.** Every script that deploys to,
benches on, or otherwise drives a fleet machine re-execs itself under
`scripts/pick-bench-host.sh --run`, so the machine is claimed for the run and
released however it ends. The lock is a directory on the target, so it is shared
with the build lock and visible to every repo, agent and workstation. Check
`scripts/pick-bench-host.sh --status` before assuming a box is idle, and never
work around a busy one. `BENCH_NO_LOCK=1` exists only for debugging the picker.

**Cross-repo work goes through GitHub, not chat.** One board covers all five
repos: <https://github.com/users/matthewdeaves/projects/8>. Columns are
`Triage / Measuring / Ready / In progress / Blocked / Done`, with `Source` and
`Evidence` fields. File cross-repo work as an issue and put it on the board:

```sh
gh issue create -R matthewdeaves/<repo> --project Retro \
  --label from:port,needs-measurement --title "..." --body "..."
```

Labels, the same four in every repo: **`from:infra`** raised by the server side
for a port to act on, **`from:port`** raised by a port for another repo,
**`needs-measurement`** the claim has no number or hardware repro behind it yet,
**`cross-port`** it affects more than one port, so expect sibling issues.

**Anything one session raises at another starts in `Triage` with
`needs-measurement`, and is not worked until a human or a measurement moves it.**
An issue written by another agent carries no more evidence than the reasoning
that produced it, and it arrives looking exactly like one backed by a bench run.
That gate is the whole reason the board has a `Measuring` column. The same
finding really does recur across ports (the PowerPC SDL2 `--disable-joystick`
issue was filed in three repos on the same day), so `cross-port` is worth using,
but file the sibling issues rather than assuming the fix transfers.

**This repo is PUBLIC. `retro-server-infra` is PRIVATE.** It describes the
topology, firewall rules and admin surface of a live host. Never copy addresses,
key material, tunnel tokens or `.env` content out of it into this repo, in code,
docs or a commit message. Referring to a server release tag is fine; describing
where it runs is not.

## Read on demand

- `README.md`, public overview: fleet, framerates, install
- `docs/BUILD.md`, build flags, patch class, deploy layout, game data
- `docs/BENCH.md`, the harness and its safety rails
- `docs/CONFIG.md`, cvar reference and the feature inventory with commits
- `docs/HD_PACK.md`, `docs/WATCHLINK.md`, `server/README.md`
- `docs/STATUS.md`, release history and what is open
- `MISTAKES.md`, **read before lighting up anything that smells "easy /
  load-time only / zero risk"**
- `docs/adr/`, 0001 slices and subtype stamping, 0002 the 5.11 pin and SDL 1.2,
  0003 arm64 is a separate question, 0004 the fat SDL framework, 0005 build
  hosts and DMG packaging, 0006 verification, 0007 config layering, 0008 the G5
  fullscreen hazard, 0009 smoke tests and benchmarks, 0010 per-machine A/B,
  0011 the Linux server, 0012 code not content, 0013 the GL 1.4 gate, 0014 the
  engine is arm64-clean, 0015 the arm64 slice ships sdl12-compat, 0016 the
  server's newer engine, 0017 the savegame arch guard
