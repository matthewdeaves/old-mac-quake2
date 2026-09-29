# Build: deploy and package

Operational how-to for building the six-slice fat `Quake2.app`, deploying it and packaging the DMG. Builds and CI run on `old-mac-build-host`; this repo's scripts are thin callers plus the shared-script pin.
Reasoning lives in the ADRs, not here: slices and cpusubtype stamping **ADR 0001**, engine pin **0002**, SDL **0004**, build hosts and DMG host **0005**, verification **0006**.
Sections: Commands, Hosts and mirror, Build targets and flags, Tiger and Panther patch class, Deploy layout, Shared scripts, DMG install, Game data, QuakeSpasm reuse.

## Commands

```sh
scripts/shared.sh pick-build-host.sh --status    # which mini is free
scripts/build.sh <g3|g4|g5|lion>                 # one slice, claims a host, flocks
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo; pinned host; imac-2019 lion leg opt-in (below)
scripts/deploy.sh <machine>                      # ships build/q2-fat over ssh
scripts/make-dmg.sh                              # → dist/Quake2-OldMac-<ver>.dmg, on a Tiger box
scripts/deploy-dmg.sh <machine>                  # install from the mounted image, as a human does
scripts/smoke-dmg.sh <machine>                   # launch the installed copy with the PRODUCTION config
scripts/bench.sh <machine> <demo> <WxH> [runs]   # see docs/BENCH.md
```

`BUILD_HOST=<alias>` pins a mini. `DMG_HOST=<alias>` pins the packaging box (must be Tiger).

## Hosts and mirror

The remote source mirror is `~/oldmac/quake2/`. `rsync --delete` is scoped to that child only. The latest per-target compiler logs live in its `logs/` child, and `build-fat.sh` uses its `fat-stage/` child for lipo input and output.

`build-fat.sh`'s g3/g4/g5/**and x86_64 (`lion`)** legs and the final lipo all stay on the one pinned `BUILD_HOST` by default. `imac-2019`'s Sequoia `ld64` emits `LC_MAIN` where real Lion's 2011 dyld needs `LC_UNIXTHREAD`, a linker-generation gap no compiler flag closes, so a `lion` leg built there segfaults instantly on real Lion (BUGFIXES #45, shipped in a v2.11.0 RC). Opt in with `QUAKE2_USE_IMAC2019_LION=1` only if you will `otool -l` the result and confirm `LC_UNIXTHREAD` before shipping. Issue #41.

**Never run two PPC builds on the same mini at once** (ADR 0005). Two builds on different minis are fine.

## Build targets and flags

Chip family plus SDK, not machine identity. Full table with reasoning in ADR 0001.

- `g3` → yosemite. `-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk
  -mmacosx-version-min=10.3 -mcpu=750 -O3`
- `g4` → sawtooth, quicksilver, mini-g4. Same SDK and min-OS, plus
  `-mcpu=7400 -faltivec -maltivec -mabi=altivec -mtune=7450 -O3
  -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`
- `g5` → imac-g5. `-isysroot /Developer/SDKs/MacOSX10.5.sdk
  -mmacosx-version-min=10.5 -mcpu=970 -maltivec -mabi=altivec -O3
  -DQ2_ARCH_PPC970`
- `lion` → mini-intel, imac-2019. `-arch x86_64 -mmacosx-version-min=10.6 -O3`

All of these ride into the build through `OSX_ARCH=`, because yquake2's Makefile references rather than assigns it (`CFLAGS += $(OSX_ARCH)`, `LDFLAGS := $(OSX_ARCH) -lm`, and the `SDLMain.m` Objective-C rule), so `-isysroot`, `-mmacosx-version-min`, `-arch`, `-mcpu` and `-O3` all travel together. `-Wl,-w` suppresses the 10.3.9 SDK's crt1.o "-mlong-branch no longer needed" warnings.

Makefile knobs `scripts/build.sh` overrides: `WITH_CDA=no`, `WITH_OGG=no`, `WITH_OPENAL=no`, `WITH_SYSTEMWIDE=no`; `WITH_RETEXTURING` and `WITH_ZIP` stay `yes`.

Four artifacts per slice: `quake2`, `q2ded`, `ref_gl.so`, `baseq2/game.so`.

## Tiger and Panther patch class

Patches applied to 5.11 (which targets 10.6+) so it builds against the old SDKs. Three landed as separate `patch:` commits in Phase A:

- gate `-rpath` on 10.5+ deployment targets (Makefile)
- link Darwin shared libraries with `-dynamiclib`, not `-shared` (Makefile)
- include `sys/types.h` before `sys/mman.h` on the Panther 10.3.9 SDK (`hunk.c`)

The class to expect if a new file is added: `NSAlertStyle` macros (10.4 only has `NSCriticalAlertStyle`), `stringWithCString:encoding:` (10.4+, needs a `stringWithCString:` fallback on 10.3), `kCGLCEMPEngine` (10.4.8+, absent from the 10.3.9 SDK headers, wrap in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`), and Objective-C 2.0 dot notation, which gcc-4.0 does not parse. **Do not pre-patch speculatively**, let `make` surface the list.

## Deploy layout

See `docs/DEPLOY.md`.

## Shared scripts

See `docs/DEPLOY.md`.

## DMG install

See `docs/DEPLOY.md`.

## Game data

See `docs/DEPLOY.md`.

## Reuse from QuakeSpasm

Do not duplicate: SSH config with legacy crypto and `~/.ssh/id_rsa_tiger`; the cross-build toolchain on the minis; the vendored prerequisites in `~/quakespasm/prereqs/` (Xcode 3.2.6, Xcode 2.5, SDL 1.2.15 sources, ~5 GB); `host-bin/qsreboot.sh`, already on every bench Mac and the reboot-recovery path for Q2 crashes too.

## Source stamps

`scripts/source-stamp.sh` is canonical in buildhost. Port-specific exclusions belong in `scripts/source-stamp-excludes.sh`; the shared helper takes that list as an argument. See issue #20.
