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
| **imac-g5** PowerMac8,2 (2004) *(pending, not yet networked)* | 2.0 GHz PPC 970FX | ATI Radeon 9600 (likely) | 10.5.8 Leopard |
| **mini-intel** Macmini2,1 (2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion |
| **imac-2019** iMac19,1 (2019) | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia |

The iMac G5 is **not on the network yet** — its build slice + generic
baseline cfg exist (added 2026-05-31), but exact `hw.model`/GPU
confirmation, the per-machine overlay cfg, SSH wiring, deploy case, game
data, and first bench are all DEFERRED until it's reachable. See the
Status section.

Build targets (chip-family, not machine-identity):
- `q2-g3` → yosemite (PPC 750, 10.3.9 SDK)
- `q2-g4` → sawtooth + quicksilver + mini-g4 (PPC 7400 baseline, 10.4u SDK)
- `q2-g5` → imac-g5 (PPC 970FX, 10.5 SDK, `-mcpu=970 -maltivec`; stamps a
  distinct `ppc970` Mach-O subtype so dyld prefers it on a G5 while G4s
  fall back to ppc7400)
- `q2-lion` → mini-intel + imac-2019 (x86_64, native Lion toolchain)

SSH aliases + legacy crypto config: same `~/.ssh/config` as the
QuakeSpasm project. **Don't duplicate the SSH setup.** Reuse.

## yquake2 5.11 build basics

The engine builds three artifacts: `quake2` (client), `q2ded` (dedicated
server, can disable), `ref_gl.so` (GL renderer, loaded at runtime).
**The renderer is a runtime-loaded shared library on Linux/Windows,
but on macOS the build system bundles it into the .app — same end
result, different mechanics from QuakeSpasm.**

Makefile knobs at the top of `yquake2/Makefile` (all default `yes`):
`WITH_CDA`, `WITH_OGG`, `WITH_OPENAL`, `WITH_RETEXTURING`, `WITH_ZIP`,
`WITH_SYSTEMWIDE`. `scripts/build.sh` sed-overrides the first three to
`no` per build (we have no CD, no OGG/OpenAL deps installed on PPC),
leaves `WITH_RETEXTURING=yes` (now satisfied by the vendored
`stb_image.h` — see HD_PACK.md), `WITH_ZIP=yes` (libz ships in Tiger),
and `WITH_SYSTEMWIDE=no`. `OSX_ARCH` defaults to `-arch i386 -arch
x86_64`; we override per target via `OSX_ARCH=` in `scripts/build.sh`.

PPC build flag override pattern (matches QuakeSpasm):
- G3:   `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4:   `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`
- G5:   `-isysroot /Developer/SDKs/MacOSX10.5.sdk   -mmacosx-version-min=10.5   -arch ppc -mcpu=970 -maltivec -mabi=altivec -O3 -DQ2_ARCH_PPC970`
- Lion: `-arch x86_64 -mmacosx-version-min=10.7 -O3`

The `-DQ2_ARCH_PPC970` flag is load-bearing: Apple gcc defines no
`__ppc970__` macro for `-mcpu=970` (only `__VEC__`/`__ALTIVEC__`/`__ppc__`,
same as the G4), so the 970 slice is indistinguishable from the 7400 slice
at compile time. `misc.c` checks `Q2_ARCH_PPC970` FIRST — before the
`__VEC__ → ppc7400` branch — to load the generic-G5 baseline. The 10.5 SDK
is already installed on mini-intel at `/Developer/SDKs/MacOSX10.5.sdk`.

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

## Multi-tenancy on mini-intel (shared with the QuakeSpasm sister project)

`mini-intel` is the cross-build host for **both** this Q2 port and the
QuakeSpasm sister project at `~/quakespasm/`. The two projects coexist
on the same Lion box by using **separate upload directories** for source
rsync and **workstation-local** build artifacts. Don't conflate them.

| Resource | QuakeSpasm uses | Q2 uses (must) |
|---|---|---|
| Source rsync target on mini-intel | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd on mini-intel | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` (Q2's makefile is at the top level) |
| Local flock for build serialization | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| Local build outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

**Shared (read-only)**: `/Developer/SDKs/MacOSX10.3.9.sdk`,
`/Developer/SDKs/MacOSX10.4u.sdk`, `/usr/bin/gcc-4.0`, `/usr/bin/clang`.
**Never modify** anything under `/Developer/SDKs/` or the system
toolchain — QS depends on the current install and re-installing Xcode
3.2.6 + 2.5 from the vendored DMGs is a multi-hour recovery operation.

**Concurrent builds are safe given the above isolation** — each project
flocks on its own workstation-side lock, rsyncs to its own dir on
mini-intel, and `make -jN` operates in its own dir. The only contention
is CPU/memory on the dual-core Core 2 Duo, which means concurrent
compiles take ~2× wall clock but produce correct binaries. If mini-intel
is already mid-compile for QS when Q2 wants to build, prefer to wait
(serial is faster than 2× concurrent on a 2-core box) — but it's not a
correctness issue.

**Tell-tale of accidental conflation**: if `scripts/build.sh` ends up
rsyncing to `mini-intel:~/` (no project prefix) or to
`mini-intel:quakespasm/`, the Q2 build will overwrite QS source and
break the sister project. The first version of Q2's `build.sh` should
hard-code `mini-intel:quake2/` and assert the path is project-local
before rsync.

## Bench-and-commit cadence (carry over from QuakeSpasm)

Same discipline: smoke bench on dirty tree, commit code change, then
`scripts/bench-and-commit.sh "Phase X" --quick` on clean tree to land
the official benchmark rows. Full grid only at end-of-round. Never
wipe `benchmarks/results.csv` mid-round.

Q2's timedemo invocation differs from Q1:
- Q1: `+timedemo demo1`
- Q2: `+timedemo demo1.dm2` (the `.dm2` is required — they're separate
  files in `baseq2/demos/`)

Q2 retail paks (pak0/pak1/pak2) ship TWO playable demos: `demo1.dm2`
(intro flythrough) and `demo2.dm2` (gameplay). Despite Q1's three-demo
heritage, Q2's `demo3.dm2` is NOT in any of the retail pak files —
attempting to play it fails with "Couldn't open demos/demo3.dm2". Bench
scripts default to demo1+demo2 only.

## Toggleable knobs

Same discipline as QuakeSpasm: every per-target visual / perf decision
must be flippable at runtime (cvar) or at launch (`-flag`). Custom cvars
this fork adds on top of stock yquake2 5.11:

| cvar | what | default per machine |
|---|---|---|
| `gl_fog` (+ mode/start/end/rgb) | cvar-driven GL_FOG | on (all) |
| `gl_waterwarp` | underwater frustum sine-warp | on (all) |
| `gl_decals` `gl_decal_max/life/fade` | KMQuake2 world decals | on; cap 8 (G3)→128 (imac) |
| `gl_msaa_samples` | MSAA (CVAR_LATCH) | 0 (PPC fixed-func)→8 (imac) |
| `gl_lightmap_subrect` | dirty-column dynamic LM upload | on (no-op if dlights off) |
| `gl_groupdraw` | batched `qglDrawElements` (+ CVA lock) | on G4+/x86, off G3 |
| `gl_minlight` `gl_skydistance` | lightmap floor / sky extent | per-machine |
| `gl_particle_square` `gl_pointsprites` `r_2D_unfiltered` | particle/HUD tweaks | per-machine |
| `gl_glows` | sphere-map energy shell glow | on multitex, off G3/sawtooth |
| `gl_trans_lighting` | lightmapped glass/grates (map-load latched) | on multitex, off G3/sawtooth |
| `gl_caustics` | water-surface caustic overlay | on multitex, off G3/sawtooth |
| `gl_zfix` | polygon-offset coplanar surfaces | on (all) |
| `gl_farsee` | extended far clip (CVAR_LATCH) | on x86 only |
| `gl_bloom` (+ alpha/darken/size) | fixed-function light bloom | **off — WIP, broken on GL1, see MISTAKES.md** |

## Icon pipeline philosophy

`scripts/make-icon.py` ships **conservative defaults**: edge-flood-fill
bg removal that preserves all interior detail, no auto-scrubbing of
interior bg-coloured pockets. The `--scrub-interior` knob exists for AI-
generated artwork that has bg leaking through logo glyph gaps or
detail-sparse areas, but the heuristics (size + score-purity + annulus
darkness) can't reliably distinguish bg-bleed from saturated specular
highlights on metallic surfaces.

**Use Photoshop touch-up over algorithmic perfection.** The proven
workflow for the Q1+Q2 icons we shipped:
1. Run `make-icon.py` with defaults to produce a conservative
   transparent-bg master + a magenta-composited preview.
2. User opens the master in Photoshop, paints any visible bg pockets
   to alpha=0 using the magenta preview as a guide.
3. User saves back as RGBA PNG, hands it back via `--keep-bg` to
   regenerate the ICNS without re-running bg removal.

Don't burn cycles trying to make `--scrub-interior` work perfectly on a
new artwork — if defaults leave visible bg pockets, ship to Photoshop.

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
- **Cross-build toolchain on mini-intel** — gcc-4.0 + 10.3.9/10.4u/10.5 SDKs already installed
- **Vendored prereqs/** — Xcode 3.2.6, Xcode 2.5, SDL 1.2.15 sources live in
  `~/quakespasm/prereqs/`. ~5 GB. Don't duplicate; reference.
- **host-bin tooling** — `qsreboot.sh` already installed on every bench
  Mac. Same reboot-recovery path applies to Q2 crashes.
- **Legacy crypto SSH** — `~/.ssh/id_rsa_tiger` already wired up.

## Don't run PPC builds in parallel (g3 / g4 / g5)

Same race condition as QuakeSpasm: concurrent invocations rsync to the
same path on mini-intel and `make -j2` in the same dir. The .o files
race and the binary ends up stamped with the *other* target's CPU
subtype. Symptom: G3 binary becomes `ppc7400`, Panther loads it, then
crashes during NIB init on a 750. With the G5 slice added the hazard is
worse (three PPC targets now share the same `-arch ppc` .o tree, only
differing by `-mcpu`), so the wrong-subtype stamp is even easier to hit.
`scripts/build.sh` takes a flock to serialize — don't bypass.
`scripts/build-fat.sh` runs g3→g4→g5→lion strictly sequentially for the
same reason.

## Deploy is fat-only (no per-target mode)

`scripts/deploy.sh <machine>` ships ONE thing — the universal `Quake2.app`
from `build/q2-fat/`. The previous dual-mode design (per-target flat
layout vs fat .app) had a foot-gun: both modes wrote to the same
`~/Desktop/quake2/` with `rsync --delete`, so running the wrong one
wiped out the .app. Per-target mode is gone. `scripts/build.sh g3|g4|lion`
still exists for fast single-slice iteration during dev, but those slices
only feed `scripts/build-fat.sh` — they don't deploy independently.

## Bundle is self-contained (CFBundle-loaded autoexec, two layers)

Autoexec cfgs ship INSIDE `Quake2.app/Contents/Resources/` and load in
TWO layers (mirrors the QuakeSpasm sister project — "best on known
machines, sane generic on everything else"):

- **Layer 1 — per-arch baseline** (`autoexec-ppc750/ppc7400/ppc970/
  x86_64.cfg`): selected at COMPILE time. dyld picks the fat slice that
  matches the host CPU, so the baseline baked into that slice is the one
  that runs. This is the floor that makes the game playable on ANY
  G3/G4/G5/Intel Mac, not just the bench boxes. Selection lives in
  `misc.c` via `#if Q2_ARCH_PPC970 / __VEC__ / __ppc__ / __x86_64__`.
  The `Q2_ARCH_PPC970` check MUST come first — the 970 slice also
  defines `__VEC__`, so without the explicit build macro it would fall
  into the ppc7400 branch.
- **Layer 2 — per-machine overlay** (`autoexec-<machine>.cfg`): selected
  at RUNTIME via `sysctlbyname("hw.model", ...)`, layered AFTER the
  baseline so it wins on the six known fleet boxes. Unknown models keep
  just the Layer-1 baseline.

Both layers append to `Cbuf` in order (baseline first, overlay second),
so the overlay's `set` lines override the baseline's. See
`yquake2/src/common/misc.c:Q2_ExecConfigFromBundle` and the call site in
`Qcommon_Init` AFTER `CL_Init()` (the call site placement is load-bearing
— renderer cvars like `gl_picmip` don't exist until `CL_Init` has loaded
`ref_gl.so`, so an earlier hook would silently drop those cvar lines as
unknown commands).

The cfgs use `set CVAR VALUE` syntax (not bare `CVAR VALUE`). This
matters because Q2's command parser only routes bare assignments
through `Cvar_Command`, which IGNORES unknown cvars — but `set` creates
the cvar if it doesn't yet exist, so renderer cvars that aren't
registered until `ref_gl.so` lazy-loads still take effect when the
DLL eventually pulls them in via `Cvar_Get` (which honours the
existing value).

End-user install: drop `Quake2.app` + your own `baseq2/pak*.pak` next
to each other. The .app travels with all four per-arch baselines + all
six machines' per-machine overlays inside it — same .app runs on G3
Panther, G4 Tiger, G5 Leopard, Intel Lion, and modern Sequoia.

## Bench / screenshot scripts pass -noarchautoexec

`scripts/bench.sh` and `scripts/screenshot.sh` need full cmdline cvar
control (the per-resolution sweep, the cmd-buffer wait chains). The
engine accepts `-noarchautoexec` to suppress the bundle hook entirely.
Use that flag whenever you need a deterministic measurement that
shouldn't be coloured by the per-machine production defaults.

To A/B a single cvar tweak against the production cfg, use `+cmd "set
X Y"` instead — `+cmd` runs as a LATE command, after the bundle exec,
so it overrides cleanly. If the tweak wins, fold the new value into
`scripts/bundle/autoexec-<machine>.cfg`, redeploy, re-bench.

## Status

- 2026-05-11: Phase A landed. Self-contained fat universal `Quake2.app`
  ships to all 6 bench machines (yosemite/sawtooth/quicksilver/mini-g4/
  mini-intel/imac-2019). Per-machine autoexec layer loaded via CFBundle
  works on PPC (Tiger + Panther), Intel Lion, and Intel Sequoia. TGA
  screenshot writer patched for top-down orientation.
- 2026-05-19: imac-2019 baseline captured — 701.6 fps @ 1024×768,
  709.2 fps @ 640×480 (Polaris 20 totally unbound by GL1 fixed-func).
  Phase A baseline now complete across all 6 machines; tagged `v1.0.0`
  as the canonical re-bench reference build.
- 2026-05-21: Phase B/C cherry-pick round landed. `gl_fog` (cvar-driven
  GL_FOG, ported from KMQuake2), `gl_waterwarp` (underwater frustum
  sine-warp), `gl_lightmap_subrect` (dirty-column-only dynamic upload),
  `jpeg.c` rewritten on stb_image (drops libjpeg, unlocks
  `WITH_RETEXTURING` on every slice), `gl_groupdraw` cvar +
  `r_buffer.c` (batched `qglDrawElements` dispatch per state group),
  and a CFBundle HD-texture search path in `FS_InitFilesystem` so a
  pack can ship inside the .app. THE KEY FIX of the round was
  `78c26f2`: `R_ApplyGLBuffer` must not toggle `R_EnableMultitexture` —
  doing so resets TMU1's TexEnv to `GL_REPLACE`, destroying the
  `GL_COMBINE_EXT` modulate setup `R_DrawWorld` put in place and
  rendering walls/floors as overbright lightmap-only (with OBB4 → flat
  yellow/beige). The buffer must trust the outer code to own the mtex
  enable lifecycle. See `r_buffer.c` for the load-bearing comment.
  Post-fix every multitex platform (mini-g4 / quicksilver / mini-intel)
  renders correctly with full retex + OBB4. Yosemite ULTIMATE shipped
  (25.10 / 45.15 fps with picmip 0 + trilinear + alias shadows + fog).
- 2026-05-29: v2.1.0 round (tagged). Shipped: `gl_glows` (sphere-map
  energy shell), `gl_trans_lighting` (lightmapped glass/grates),
  `gl_caustics` (water-surface caustic overlay) — all ON for the multitex
  boxes, OFF on yosemite/sawtooth; `gl_zfix` (coplanar z-fix) everywhere;
  `gl_farsee` on the x86 boxes; CVA (`glLockArraysEXT`) on the group-draw
  path (fps-neutral, kept for parity). Fixed a latent bug: the procedural
  shell/caustic textures (and bloom's) are now protected in
  `R_FreeUnusedImages` — they were being freed on map change. `gl_bloom`
  (fixed-function light bloom) is wired but DISABLED — prohibitive on PPC
  (quicksilver 25fps) and renders incorrectly on the GL1 path; see
  MISTAKES.md. `scripts/make-dmg.sh` added (Panther-built UDZO `.dmg`).
  Note: G4 fps floor is now ~40 for feature work (user pref), not 60.
- 2026-05-31: iMac G5 (PowerMac8,2, 970FX @ 2.0 GHz, Leopard 10.5.8)
  added as a 4th PowerPC fat slice (branch `imac-g5-target`). New `g5`
  build target (10.5 SDK, `-mcpu=970 -maltivec -DQ2_ARCH_PPC970`), 4-way
  lipo in `build-fat.sh` (ppc750+ppc7400+ppc970+x86_64). Also closed a
  gap vs the QuakeSpasm design: Q2 previously had ONLY the per-machine
  (hw.model) config layer, so unknown Macs got stock yquake2 defaults.
  Added the **per-arch baseline layer** (`autoexec-ppc750/ppc7400/ppc970/
  x86_64.cfg`, compile-time selected in `misc.c`) so ANY G3/G4/G5/Intel
  Mac now gets a sane generic tune, with the per-machine overlay still
  winning on the six known boxes. ppc970 baseline seeded conservatively
  from the proven ppc7400 tune (won't regress). **DEFERRED until the iMac
  G5 is on the network:** confirm exact hw.model + GPU via SSH; add
  per-machine `autoexec-imac-g5.cfg` + a `PowerMac8,2` entry to the
  hw.model map in `misc.c`; add an `imac-g5` HOST case to `deploy.sh`;
  wire SSH config (Leopard OpenSSH may need the legacy-crypto block);
  ship game data; first bench. Build/lipo verified offline (all four
  slices present); no runtime test yet (no G5 reachable).
- yquake2 cloned at QUAKE2_5_11 tag (commit `033550cd`, 2013-05-20).
- Reference repos cloned for Phase B (yquake2 latest) and Phase C
  (KMQuake2 visual features, FoD Q2 Mac Cocoa patterns).
- Next: bloom redo (dedicated render-target texture, sub-res budget);
  AltiVec `R_BuildLightMap`; GL1 gamma correction; re-bench mini-g4 cool.
