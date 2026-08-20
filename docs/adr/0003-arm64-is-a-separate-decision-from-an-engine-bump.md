# 3. arm64 is a separate decision from an engine bump

Date: 2026-08-20
Status: accepted (as a correction); no arm64 slice is shipped

## Context

arm64 was closed as out of scope in v2.6.0 (issue #6), on the stated ground of
"matching the sister ports". Two decisions had been fused into one: "the engine
is old" and "therefore no Apple Silicon". They are not the same decision.

## Decision

**Record the two as separate questions with separate justifications, and stop
citing the engine pin as the reason arm64 is closed.**

| Goal | What it actually needs | Engine bump? |
|---|---|---|
| arm64 slice | an arm64 implementation of the SDL 1.2 API, and a `lipo` that can fuse arm64 | no |
| Upstream security fixes | an 8.x base | yes |

The real coupling is narrow: 5.11 means SDL 1.2 (ADR 0002), and SDL 1.2 upstream
never produced an arm64 build, so the shipped `SDL.framework` has no arm64 slice.
What an arm64 engine slice needs is an arm64 **implementation of the SDL 1.2
API**, not a newer engine. `sdl12-compat` (libsdl-org) is exactly that: the SDL
1.2 API on top of SDL2, and it is arm64-native.

`SDL.framework` here is already fat with four slices (`x86_64 i386 ppc ppc970`),
two of them hand-built. A fifth arm64 slice built from `sdl12-compat`, carrying
the same install name, would be selected by dyld on CPU alone exactly as the
others are (ADR 0001). PowerPC and Intel keep real SDL 1.2; only the new slice
would run the shim; the engine source would not change. **INFERRED** — not
built, not linked, not run.

### What sdl12-compat can and cannot do (researched 2026-08-20)

Scope corrected after checking it. An earlier draft of this ADR implied it was a
general answer to SDL 1.2 on modern systems. It is not.

- **It cannot help PowerPC, ever.** It `dlopen`s SDL2 at runtime and enforces a
  **minimum of SDL2 2.0.7 on macOS** (`src/SDL12_compat.c:1293`, checked at
  `:1755`). The PowerPC ceiling is **2.0.3** (ADR 0002 and the sister Half-Life
  `docs/adr/0004`), four releases short. So it is only ever a candidate for the
  arm64 slice, never a way to modernise the PowerPC ones.
- **It does build for arm64 on macOS**, verified on the orchestration Mac, and
  arm64 is in upstream CI. Upstream ships no macOS binaries, so we would build
  it ourselves.
- **It does not make an existing binary run.** It replaces the SDL library, not
  the game's Mach-O. The engine still has to be compiled for arm64 either way.
- **Known risks, and they are not small for a GL game.** Its OpenGL scaling path
  redirects rendering through a fake backbuffer and is documented to break
  applications that use FBOs; its macOS quirks table is empty
  (`src/SDL12_compat.c:1490-1493`), so no per-game workaround auto-applies; and
  there is an open upstream bug (#216) about a Quake II software renderer
  showing wrong palette colours under it.

So the honest position: `sdl12-compat` remains the cheapest route to an arm64
slice **without** touching the engine, and it is the only route that leaves the
PowerPC and Intel slices completely alone. The alternative is an engine with a
real SDL2 path, which means the bump this ADR exists to keep separate. Neither
is free. Prove the shim on `q2dm1` with the GL1 renderer before committing to
it.

The old reason for closing arm64 has expired: the sister Half-Life port now
ships a five-slice fat including `arm64`, so "matching the sister ports" would
today argue *for* it.

## Status

No arm64 slice is shipped and none is planned in the current round. The point of
this record is that a future round must argue arm64 on the SDL question and on
whether the build host's `lipo` can fuse it, and must not close it by pointing
at the engine version.

Two things are known from the sister port and worth carrying: Lion's `lipo` can
write a correct fat containing arm64 but cannot NAME the slice, printing a
numeric `cputype`; and arm64 itself cannot be built on a Lion mini, whose
toolchain predates it. **INFERRED for this repo** — neither has been tested with
this tree's artifacts.
