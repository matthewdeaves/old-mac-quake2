# 15. The arm64 slice ships sdl12-compat over an SDL2 we build

Date: 2026-08-20

Status: accepted. Supersedes the conclusion of
[0014](0014-the-engine-is-arm64-clean-only-sdl-1-2-is-not.md), whose finding
about the engine holds and whose recommendation about the shim does not.

## Context

0014 measured that the engine is arm64-clean: `q2ded` and `baseq2/game.so`
built native arm64, and only the client's SDL-facing files failed, all on
`'SDL/SDL.h' file not found`. That finding stands and is why this was cheap.

Its recommendation was to defer arm64 into an engine-bump decision rather than
ship `sdl12-compat`, on the grounds that the shim means a four-deep stack:
engine -> sdl12-compat -> sdl2-compat -> SDL3. That description was checked
again here and is accurate **of Homebrew** (`/opt/homebrew/lib/libSDL2-2.0.0.dylib`
resolves into `Cellar/sdl2-compat/2.32.70`). It is not a description of what we
would ship, because it assumes we would use the system's SDL2.

`sdl12-compat` has **no link-time dependency on SDL2 at all**. It `dlopen`s one
at runtime, and among the locations it tries are `@loader_path/` and
`@executable_path/libSDL2-2.0.0.dylib` (`src/SDL12_compat.c`, the
`dylib_locations` table). Verified on the shim we build: `otool -L` lists
AppKit, Foundation, CoreFoundation, ApplicationServices, libobjc and libSystem,
and nothing else. `scripts/build-arm64.sh` asserts this on every run, because
if it ever stops being true the whole argument here collapses.

So the stack is whatever SDL2 we put beside the binary. Shipping our own makes
it two layers, both ours:

    quake2 (arm64) -> sdl12-compat 1.2.76 -> SDL 2.32.4

Both are built from pinned upstream sources, the same SDL 2.32.4 the Half-Life
port already ships in its own arm64 slice.

## Decision

Ship an arm64 slice, in all FOUR shipped Mach-O products: `quake2`, `q2ded`,
`ref_gl.so` and `baseq2/game.so`. It is the sixth member of the same fat,
selected by dyld on CPU subtype alone exactly as the other five are.

The arm64 member of `MacOSX/SDL.framework/Versions/A/SDL` is `sdl12-compat`.
The `ppc`, `ppc970`, `i386` and `x86_64` members of that same file remain
genuine SDL 1.2 and are untouched. No PowerPC or Intel machine loads the shim.

`libSDL2-2.0.0.dylib` ships beside the executable inside the bundle. It is not
committed: this repo gitignores `*.dylib`, and `scripts/build-arm64.sh` builds
it from source, so `deploy.sh` and `make-dmg.sh` take it from
`build/arm64/release/` and say so when it is missing.

arm64 is **optional at fuse time**. A mini cannot build it, so requiring it
would make a release impossible from the normal build path, and its absence is
a Rosetta 2 downgrade rather than a fault. `build-fat.sh` and `make-dmg.sh`
both say which of the two happened.

## The ObjC class collision this needed

The first arm64 run printed:

    objc: Class SDLApplication is implemented in both .../quake2 and
    .../libSDL2-2.0.0.dylib. This may cause spurious casting failures and
    mysterious crashes. One of the duplicates must be removed or renamed.

yquake2 compiles its own `src/backends/sdl_osx/SDLMain.m`, which declares
`@interface SDLApplication : NSApplication`. SDL2's Cocoa backend declares a
class of the same name. On the other five slices there is no collision, because
they link real SDL 1.2 and never load an SDL2 at all.

Fixed by renaming ours to `YQ2Application`. Nothing outside that file names the
class and `SDL_USE_NIB_FILE` (the only path that would bind it by name from a
nib) is off, so the rename is local. It is applied on every slice rather than
conditionally, so there is one spelling to reason about. The warning is gone,
confirmed on a rebuilt arm64 client.

## Consequences

- Apple Silicon runs this port natively, in all four products. Measured on an
  M5, `demo1.dm2`, vsync off, nothing else running: 483 fps at 640x480, 284 fps
  windowed at 1710x1107, 444 fps fullscreen at the desktop capture.
- `scripts/bundle/autoexec-arm64.cfg` is new and is the first config in this
  port whose numbers come from the machine it targets rather than a neighbour.
- `vid_desktopfullscreen 1` is set on this slice. Apple Silicon Macs ship many
  different panels and an external display can change the answer between
  launches, so a captured desktop resolution is the right default here. The
  engine read the desktop correctly through the shim in both cases tested,
  1710x1107 built-in and 2560x1080 attached.
- Signing happens **before** the fuse. `build-fat.sh` lipos on a Lion mini,
  which cannot codesign arm64, and an unsigned arm64 Mach-O is SIGKILLed on
  load with no diagnostic.

## Two measurements that were wrong first, and must not be repeated

- **59.5 fps.** Apple's GL defaults vsync ON, which pins the result just under
  60 and reads exactly like a slow renderer. Bench with `gl_swapinterval 0`.
- **34.7 fps fullscreen.** That was several earlier instances of the game still
  running in the background competing for the GPU. Clean, the same run is
  444 fps. This was very nearly written down as "the shim's OpenGL scaling
  path is slow", which would have been false. Kill every instance before
  benching, and match on the command name: these are launched as `./quake2`,
  so a `pkill -f` on the directory path does not match them.

## What is still open

The risks 0014 raised against the shim are reduced, not eliminated. Its OpenGL
scaling path is documented upstream to misbehave with FBO users and its macOS
quirks table is empty. Neither has been observed here across map load, a full
timedemo, windowed and fullscreen. Worth re-checking on any shim or engine bump.
