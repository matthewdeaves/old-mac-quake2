# 13. The GL 1.4 gate is a version-string test, and the G3 runs fine without it

Date: 2026-08-20
Status: accepted (measured on hardware)

## Context

Two questions were open and had been treated as one: whether this port could
move off yquake2 5.11 onto a current engine, and whether a G3 could ever have
hardware OpenGL under a current engine. Both were answered on 2026-08-20 by
building current yquake2 (8.71pre, upstream 69599f5) for `ppc750` and running
it on `yosemite` (PowerMac1,1, 449 MHz G3, ATI Rage 128, 10.3.9).

Note that **our shipped 5.11 renderer has no version gate at all**. The gate
exists only in current yquake2, so this is a question about the engine bump,
not about anything shipping today.

## What was measured

**Current yquake2 builds for `ppc750` with gcc-4.0 against the 10.3.9 SDK.**
Client, GL1 renderer and game logic, all stamped `ppc750`. Of 152 source files
outside the GL3 renderer, 150 compile clean; the two that do not are the SDL3
backends, which are not built when targeting SDL2.

**There are TWO GL 1.4 version-string gates, not one.** `gl1_main.c:1543` is
the one usually cited, but the one that actually refuses the context is
`gl1_sdl.c:287` in `RI_InitContext`. Relaxing only the first gets you as far
as `ref_gl::R_SetMode() - invalid mode` and no further.

**With both relaxed, the G3 runs the current GL1 renderer on hardware GL:**

```
GL_VENDOR:   ATI Technologies Inc.
GL_RENDERER: ATI Rage 128 OpenGL Engine
GL_VERSION:  1.1 ATI-1.3.28
 - Multitexturing:            Okay
 - Non power of two textures: Failed
 - Point parameters:          Failed
 - Anisotropic:               Failed
689 frames, 19.5 seconds: 35.3 fps      (demo1, 640x400 windowed)
```

The renderer is genuinely rasterising rather than short-circuiting. Frame rate
scales with pixel count the way a fillrate-bound part must:

| Resolution | Pixels vs 320x240 | fps |
|---|---|---|
| 320x240 | 1x | 39.6 |
| 640x480 | 4x | 20.0 |
| 800x600 | 6.25x | 11.9 |

So **a 1998 card advertising GL 1.1 runs the renderer that claims to require
1.4.** The version string is not a capability requirement.

## Decision

**Treat the 1.4 gate as a version-string test, not a capability test, and
relax both instances if this port moves to a current engine.** The renderer's
real requirement is `GL_ARB_multitexture`, which this hardware has.

## Four portability fixes the bump needs, all small

1. **`Sys_Realpath` calls `realpath(in, NULL)`** (`backends/unix/system.c`).
   Letting the callee malloc the buffer is POSIX.1-2008; 10.3's libc predates
   it and dereferences the NULL. The process dies with `EXC_BAD_ACCESS` at
   `0x0` inside `FS_InitFilesystem` before printing a single line. A
   caller-supplied `PATH_MAX` buffer is the portable spelling.
2. **`YQ2_STATIC_ASSERT` expands to `_Static_assert` for any `__GNUC__`**
   (`common/header/shared.h:79`), though the comment beside it says gcc has
   supported it only since 4.6. gcc-4.0 parses it as an implicit function
   call, which compiles with a warning and then fails at LINK with an
   undefined symbol. Needs a version test, not a compiler test.
3. **`sys/mman.h` on the 10.3.9 SDK uses `size_t` without including
   `<sys/types.h>`.** Our 5.11 tree already carries this fix in `hunk.c`.
4. **Two Makefile flags postdate gcc-4.0**: `-ffp-contract=off` and
   `-Wno-unused-result`, both gcc 4.5+. Probe for them rather than assuming.

## The one architectural problem, and it is not small

Current yquake2 loads its renderer as a separate dylib. Both the client and
that dylib link SDL2. On Panther the only SDL2 available is `panther-sdl2`
2.0.3, which is **static-only**, so each binary gets its own copy, and SDL's
Objective-C classes get registered twice in one process. The 10.3 ObjC runtime
aborts on the second registration:

```
_objc_fatal  <- class_initialize <- objc_msgSend <- Cocoa_CreateWindow
             <- SDL_CreateWindow <- GLimp_InitGraphics <- ref_gl1 RI_Init
```

Linking the renderer with `-undefined dynamic_lookup` and no `-lSDL2`, so it
binds to the single SDL instance already in the host executable, fixes it and
is what the measurements above ran on. It also drops the renderer from 2.0 MB
to 256 KB. The alternative, and probably the better answer for a real port, is
to build `panther-sdl2` as a shared `libSDL2.dylib`.

## Consequences

**Gained**

- The engine bump and the G3's renderer are no longer coupled questions, and
  neither is blocked by SDL. `PROTOCOL_VERSION` is 34 in both 5.11 and
  8.71pre, so a bump would not break wire compatibility with the Linux server
  or with a client that did not move.

**Lost**

- Nothing yet. Nothing here has shipped.

**Open**

- Visual correctness on the G3 is unverified. The demo runs, the frame counts
  are right and the scaling curve is honest, but no screenshot was captured
  and no one has compared output against the 5.11 renderer.
- The static-SDL duplication was worked around, not solved.
- Only `ppc750` was built. `ppc7400`, `ppc970`, `i386` and `x86_64` are
  untested against the current engine.
