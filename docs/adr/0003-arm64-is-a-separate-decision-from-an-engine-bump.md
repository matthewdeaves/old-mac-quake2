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
