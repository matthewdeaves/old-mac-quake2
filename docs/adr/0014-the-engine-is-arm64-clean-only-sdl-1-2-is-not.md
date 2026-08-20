# 14. The engine is arm64-clean. Only SDL 1.2 is not.

Date: 2026-08-20
Status: accepted (measured); no arm64 slice ships yet

Follows ADR 0003, which argued arm64 is a separate decision from an engine
bump but had compiled nothing. This one compiled something.

## What was measured

Building yquake2 5.11 for arm64 on the orchestration Mac produces **`q2ded`
and `baseq2/game.so`, both native arm64**, verified by `lipo -archs`. That is
the whole engine except the client's SDL-facing files: network, filesystem,
console, collision, the server, and the entire game logic.

Only four files fail, all with the same error, `'SDL/SDL.h' file not found`:
`backends/sdl/input.c`, `refresh.c`, `cd.c`, `sound.c`.

So **ADR 0003's central claim is now measured rather than inferred**: the
blocker is an arm64 implementation of the SDL 1.2 API, and nothing else in
this engine. There is no arm64 porting work hiding behind it.

## One Makefile fix, and why it looked worse than it was

`Makefile:102` refuses any `ARCH` outside `i386 x86_64 sparc64 ia64`, so an
Apple Silicon box was rejected outright with "arch arm64 is currently not
supported", which reads like an engine limitation. It is not. `ARCH` comes
from `uname -m` and is used for **nothing but that check**; every slice's real
architecture comes from `OSX_ARCH`. It is also why the PowerPC slices pass a
list that does not contain `ppc`: they cross-compile from an x86_64 Lion host,
so `uname -m` never says `ppc`. `arm64` is now in the list.

## Why no arm64 slice ships yet

`sdl12-compat` is the route ADR 0003 identified, and it does exist for arm64.
The problem is what it stands on. Homebrew's `sdl12-compat` `dlopen`s SDL2 at
runtime, and the SDL2 available beside it is `sdl2-compat`, which is itself a
shim over SDL3. That chain is engine -> sdl12-compat -> sdl2-compat -> SDL3,
three translation layers under a 1997 game. Shipping it would mean building
`sdl12-compat` against a real SDL2 rather than accepting that stack.

The known risks from ADR 0003 have not gone away either: its OpenGL scaling
path is documented to break FBO users, its macOS quirks table is empty, and
there is an open upstream bug (#216) about a **Quake II** renderer showing
wrong palette colours under it.

Meanwhile ADR 0013 established, on hardware, that current yquake2 with a real
SDL2 builds for `ppc750` and runs on a G3. That engine uses SDL2 directly, so
on it arm64 needs no shim at all. The shim is now the worse-evidenced of the
two paths, not the cheaper one.

## Decision

**Record that the engine is arm64-clean, keep the Makefile fix, and do not
ship an arm64 slice on the shim.** Revisit arm64 as part of the engine-bump
decision (ADR 0013), where it comes almost free, rather than as a shim layered
under a pinned 2018 engine.

## Consequences

**Gained**

- The arm64 question is now narrowed to exactly one dependency.
- `q2ded` for arm64 is a real artifact. The Linux server story already covers
  aarch64; this is the same engine proving out on Apple Silicon.

**Lost**

- Apple Silicon still runs the `x86_64` slice under Rosetta 2.

**Open**

- Neither `q2ded` nor `game.so` for arm64 has been run, only built.
- Nothing was built against a real (non-`sdl2-compat`) SDL2 for arm64.
