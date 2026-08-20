# 4. The fat SDL 1.2 framework is reused whole: with a dedicated ppc970 Leopard slice

Date: 2026-08-20 (records decisions taken 2026-05-11 and 2026-05-31)
Status: accepted

## Context

The engine needs SDL 1.2 on every target from a G3 on 10.3.9 to modern macOS
(ADR 0002). The sister QuakeSpasm port had already solved building SDL 1.2 for
Panther, and rebuilding it here would duplicate a solved problem.

## Decision

**Ship `MacOSX/SDL.framework` copied byte-for-byte from the QuakeSpasm project,
and keep it fat.** Verified 2026-08-20 with `lipo -info`:

    x86_64  i386  ppc  ppc970

- The **`ppc` slice** is the Panther-compatible build: 10.3.9 SDK,
  `--disable-video-x11 --disable-altivec --disable-cdrom`. It runs on the G3, the
  G4s, and on Leopard.
- The **`ppc970` slice** is SDL **1.2.15** built against the **10.5 SDK** with
  `-mcpu=970`, stamped subtype `ppc970`, added 2026-05-31. The Panther slice
  *runs* on Leopard but its fullscreen path is suspect there. dyld auto-selects
  `ppc970` on the G5; the G3 and G4s keep the Panther slice, so this is zero
  regression to every other machine.

Re-sync when QuakeSpasm rebuilds it:

    rsync -a --delete ~/quakespasm/MacOSX/SDL.framework/ ~/quake2/MacOSX/SDL.framework/

Note the `i386` SDL slice exists but no `i386` engine slice does (ADR 0001).

## The trap when rebuilding an SDL slice

**SDL's build injects `-force_cpusubtype_ALL`**, which stamps the dylib as
generic `ppc` and therefore collides with the existing `ppc` slice instead of
sitting beside it. Strip that flag from the generated `Makefile` so `-mcpu=970`
stamps a real `ppc970` subtype, then `lipo -create existing.framework
new-ppc970.dylib`. This is the same class of failure as `-faltivec` un-stamping
the engine's own subtype (ADR 0001): a build flag added for one reason quietly
undoing the property that decides which code a machine runs.

## Alternatives rejected

**Rebuild SDL 1.2 here from source.** Solved already on the sister project; the
regeneration recipe lives in `~/quakespasm/CLAUDE.md`.

**One SDL slice for all PowerPC.** The Leopard G5 needed its own; see above.

**SDL2.** See ADR 0002 and ADR 0003.

## Consequences

- SDL is a prerequisite this repo consumes rather than builds. If the framework
  is missing or thin, the link fails on the build host, not at runtime.
- The framework has its own `@executable_path` install name, so it must ship
  inside the bundle; `deploy.sh` and `make-dmg.sh` stage it there.
- Any SDL-level fix has to be made on the QuakeSpasm side and re-synced here.
