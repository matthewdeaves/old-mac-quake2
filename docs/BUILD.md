# Build: deploy and package

Operational how-to. The reasoning lives in the ADRs and is not repeated here:
slices and cpusubtype stamping **ADR 0001**, the engine pin **ADR 0002**, SDL
**ADR 0004**, build hosts and the DMG host **ADR 0005**, verification
**ADR 0006**.

## Commands

```sh
scripts/pick-build-host.sh --status              # which mini is free
scripts/build.sh <g3|g4|g5|lion>                 # one slice, claims a host, flocks
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo, one pinned host
scripts/deploy.sh <machine>                      # ships build/q2-fat over ssh
scripts/make-dmg.sh                              # → dist/Quake2-OldMac-<ver>.dmg, on a Tiger box
scripts/deploy-dmg.sh <machine>                  # install from the mounted image, as a human does
scripts/smoke-dmg.sh <machine>                   # launch the installed copy with the PRODUCTION config
scripts/bench.sh <machine> <demo> <WxH> [runs]   # see docs/BENCH.md
```

`BUILD_HOST=<alias>` pins a mini. `DMG_HOST=<alias>` pins the packaging box
(must be Tiger).

**Never run two PPC builds on the same mini at once** (ADR 0005). Two builds on
different minis are fine.

## Build targets and flags

Chip family plus SDK, not machine identity. Full table with the reasoning in
ADR 0001.

- `g3` → yosemite. `-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk
  -mmacosx-version-min=10.3 -mcpu=750 -O3`
- `g4` → sawtooth, quicksilver, mini-g4. Same SDK and min-OS, plus
  `-mcpu=7400 -faltivec -maltivec -mabi=altivec -mtune=7450 -O3
  -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`
- `g5` → imac-g5. `-isysroot /Developer/SDKs/MacOSX10.5.sdk
  -mmacosx-version-min=10.5 -mcpu=970 -maltivec -mabi=altivec -O3
  -DQ2_ARCH_PPC970`
- `lion` → mini-intel, imac-2019. `-arch x86_64 -mmacosx-version-min=10.6 -O3`

All of these ride into the build through `OSX_ARCH=`, because yquake2's Makefile
references rather than assigns it (`CFLAGS += $(OSX_ARCH)`,
`LDFLAGS := $(OSX_ARCH) -lm`, and the `SDLMain.m` Objective-C rule), so
`-isysroot`, `-mmacosx-version-min`, `-arch`, `-mcpu` and `-O3` all need to
travel together. `-Wl,-w` suppresses the 10.3.9 SDK's crt1.o "-mlong-branch no
longer needed" warnings.

Makefile knobs `scripts/build.sh` overrides: `WITH_CDA=no`, `WITH_OGG=no`,
`WITH_OPENAL=no`, `WITH_SYSTEMWIDE=no`; `WITH_RETEXTURING` and `WITH_ZIP` stay
`yes`.

Four artifacts per slice: `quake2`, `q2ded`, `ref_gl.so`, `baseq2/game.so`.

## Tiger and Panther patch class

Patches applied to 5.11 (which targets 10.6+) so it builds against the old SDKs.
Three landed as separate `patch:` commits in Phase A:

- gate `-rpath` on 10.5+ deployment targets (Makefile)
- link Darwin shared libraries with `-dynamiclib`, not `-shared` (Makefile)
- include `sys/types.h` before `sys/mman.h` on the Panther 10.3.9 SDK (`hunk.c`)

The class to expect if a new file is added: `NSAlertStyle` macros (10.4 only has
`NSCriticalAlertStyle`), `stringWithCString:encoding:` (10.4+, needs a
`stringWithCString:` fallback on 10.3), `kCGLCEMPEngine` (10.4.8+, absent from
the 10.3.9 SDK headers, wrap in
`#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`), and Objective-C 2.0 dot notation,
which gcc-4.0 does not parse. **Do not pre-patch speculatively**, let `make`
surface the list.

## Deploy layout

`scripts/deploy.sh <machine>` ships **one** thing: the universal `Quake2.app`
from `build/q2-fat/`. A previous dual-mode design (per-target flat layout versus
fat `.app`) had a foot-gun: both wrote to the same `~/Desktop/quake2/` with
`rsync --delete`, so the wrong one wiped the `.app`. Per-target deploy is gone;
`scripts/build.sh <target>` still exists for fast single-slice iteration but its
output only feeds `build-fat.sh`.

Target install layout, `~/Desktop/quake2/`:

```
Quake2.app/                 everything, incl. Contents/Resources/autoexec-*.cfg
ref_gl.so                   OUTSIDE the bundle, Q2 resolves these via basedir=.
q2ded
baseq2/game.so
baseq2/pak*.pak             the user's own data
```

`SDLMain.m` chdirs the process to the `.app`'s parent directory on a Finder
launch, so `basedir=.` resolves there.

`deploy.sh` excludes `baseq2/players/` from its `--delete` sweep. The sweep used
to wipe the four player-model directories (crakhor, cyborg, female, male) on
every deploy; canonical source is mini-g4's `/Games/Quake 2/baseq2/players/`,
cached in `.game-data/baseq2/players/`.

## Game data

Canonical set lives on quicksilver at `~/Desktop/Quake 2/`; `deploy.sh` mirrors
it. Required: `baseq2/pak0.pak` (184 MB), `pak1.pak` (13 MB, the 3.20 point
release), `pak2.pak` (45 KB), `baseq2/players/`, `baseq2/video/`. Optional:
`ctf/` (pak0 + pak1), `rogue/`, `xatrix/`. No game content is in this repo
(ADR 0012).

## Reuse from QuakeSpasm: do not duplicate

SSH config with legacy crypto and `~/.ssh/id_rsa_tiger`; the cross-build
toolchain on the minis; the vendored prerequisites in `~/quakespasm/prereqs/`
(Xcode 3.2.6, Xcode 2.5, SDL 1.2.15 sources, ~5 GB); `host-bin/qsreboot.sh`,
already installed on every bench Mac and the reboot-recovery path for Q2 crashes
too.
