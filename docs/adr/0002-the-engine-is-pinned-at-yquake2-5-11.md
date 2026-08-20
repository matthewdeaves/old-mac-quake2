# 2. The engine is pinned at yquake2 5.11, and that means SDL 1.2

Date: 2026-08-20 (records a decision taken 2026-05-11)
Status: accepted

## Context

The fleet floor is a G3 on Mac OS X 10.3.9 Panther. Whatever engine this port is
built on has to have a windowing, input and audio layer that exists for that OS.

## Decision

**Base the port on yquake2 at the `QUAKE2_5_11` tag, commit `033550cd`
(2013-05-20), vendored in-tree under `yquake2/` and edited directly on this
repo's own history.** Reasons, in order of weight:

- It is the **last release with native SDL 1.2**; 5.20 moved to SDL2. SDL 1.2 is
  the layer that reaches 10.3.9.
- It already has OS X support that backports to 10.3 / 10.4 with a small patch
  set (ADR 0005).
- The SDL backend is small, about 3,500 LOC.
- The renderer in `src/refresh/` is independent of the SDL backend, so GL1
  improvements from later yquake2 and visual features from KMQuake2 cherry-pick
  cleanly.

## This tree has ONE renderer, and it is not upstream's gl1/gl3 split

Verified in the tree, 2026-08-20:

- `yquake2/src/refresh/` builds a single **`ref_gl.so`** (GL 1.x
  fixed-function). There is no `gl1`/`gl3` directory pair, no `vid_renderer` or
  `gl_renderer` cvar, and **no renderer to choose**.
- Every shipped slice links **SDL 1.2** (`yquake2/Makefile:11`, `:221`
  `-framework SDL`; `otool -L` on the built binary shows SDL 1.2.16).

**Both of those were stated wrongly in the docs and are rejected here**, because
they described upstream yquake2 rather than the pinned 5.11 tree and had already
misled one planning exercise:

- REJECTED: "yquake2 ships two renderers, `ref_gl1` and `ref_gl3`; on the G5 set
  `vid_renderer gl1`." Not at 5.11.
- REJECTED: "For yquake2 this maps to SDL2, which it already uses." It does not.
  Choosing 5.11 *was* choosing SDL 1.2.

On macOS the renderer is bundled into the `.app` by the build system rather than
`dlopen`ed from a system path, but it is still a separate `ref_gl.so` that the
engine loads at runtime, which is why a mode change after `VID_Init` can
escalate into a full refresh-DLL reload (ADR 0007).

Makefile knobs, all default `yes`: `WITH_CDA`, `WITH_OGG`, `WITH_OPENAL`,
`WITH_RETEXTURING`, `WITH_ZIP`, `WITH_SYSTEMWIDE`. `scripts/build.sh`
sed-overrides the first three to `no` (no CD, and no OGG/OpenAL deps installed
on the PPC toolchain), keeps `WITH_RETEXTURING=yes` (satisfied by the vendored
`stb_image.h`, ADR 0012), keeps `WITH_ZIP=yes` (libz is in every SDK), and sets
`WITH_SYSTEMWIDE=no`.

## Alternatives rejected

**Bump to SDL2 / yquake2 7.21 or 8.x.** Recorded as a hard pass: it loses the
Panther and Tiger targets. **The ruling stands, but its stated evidence is
incomplete and should not be quoted as-is.** It rested on a note naming only
`leopard-sdl2` (SDL 2.0.6, Leopard 10.5+). The sister Half-Life port ships
`panther-sdl2` (SDL 2.0.3) targeting **10.3 and 10.4**, statically linked, and
it runs on the G3. So "SDL2 cannot reach Panther or Tiger" is false as written.
A bump would have to be re-argued on the real ceiling, not that one.

**yquake2remaster (Nightdive base).** Alpha-quality; parked.

## Consequences

- **The version gap is the standing security risk.** This build is 5.11;
  upstream is at 8.70. One remote overflow has been found and fixed here by
  fuzzing (ADR 0011), and one bug found in a few hours of fuzzing is not
  evidence that it is the only one. This matters most for the Linux dedicated
  server, which is the only part exposed to a network by design.
- Any cherry-pick from a later yquake2 has to be checked for state-management
  the newer tree hoisted out of the caller. The `gl1_buffer.c` port failed
  exactly there: upstream had already refactored `R_DrawWorld` to stop
  pre-configuring TMU1, ours had not (ADR 0010).
- The engine tree is ours to edit directly. There is no upstream PR path; work
  lands as commits here.
