# 1. Four slices: graded by CPU subtype, each stamped exactly

Date: 2026-08-20 (records decisions taken 2026-05-11 through 2026-07-25)
Status: accepted

## Context

`Quake2.app` is one Mach-O fat binary. `dyld` and the kernel grade a fat's
members by **CPU subtype alone**; the OS version plays no part and cannot. A
machine is handed the slice its CPU matches, and if that slice needs a newer OS
than the machine runs, the process does not start and there is no fallback to a
lower slice.

## Decision

**Ship four slices, one per CPU family, each carrying its exact cpusubtype.**

| Target | Slice | SDK | `-mmacosx-version-min` | Key flags |
|---|---|---|---|---|
| `g3` | `ppc750` (subtype 9) | 10.3.9 | 10.3 | `-mcpu=750 -O3` |
| `g4` | `ppc7400` (subtype 10) | 10.3.9 | 10.3 | `-mcpu=7400 -faltivec -maltivec -mabi=altivec -mtune=7450 -O3` |
| `g5` | `ppc970` (subtype 100) | 10.5 | 10.5 | `-mcpu=970 -maltivec -mabi=altivec -O3 -DQ2_ARCH_PPC970` |
| `lion` | `x86_64` | Lion default | 10.6 | `-arch x86_64 -O3` |

Four artifacts per slice: `quake2`, `q2ded`, `ref_gl.so`, `baseq2/game.so`.
`scripts/build.sh` builds one target, `scripts/build-fat.sh` runs g3→g4→g5→lion
and `lipo`s all four.

**The G4 slice is built at min-10.3, not min-10.4** (issue #1). A G4 booted on
Panther is handed `ppc7400` regardless of what it was built against, so building
it at 10.3 is the only thing that makes that machine work. AltiVec codegen is
independent of the SDK, so the Tiger G4s lose nothing: same-commit A/B measured
2026-07-25, demo1 @ 1024x768, quicksilver **57.10 → 57.35 fps**, mini-g4
**38.80 → 38.80 fps**. The `x86_64` slice dropped to min-10.6 for the same
reason on the Intel side (issue #5): a 64-bit Mac on Snow Leopard grades to
`x86_64` and has nowhere else to go.

**The G5 slice's 10.5 floor is real, not a testing gap.** It is built against
the 10.5 SDK; a G5 on 10.4 or 10.3 is not supported.

**`-DQ2_ARCH_PPC970` is load-bearing.** Apple gcc defines no `__ppc970__` macro
for `-mcpu=970` (only `__VEC__` / `__ALTIVEC__` / `__ppc__`, exactly as for the
G4), so the 970 slice is indistinguishable from the 7400 slice at compile time.
`misc.c` checks `Q2_ARCH_PPC970` before the `__VEC__` branch (ADR 0007).

## The cpusubtype is asserted after every build, never assumed

`-faltivec` is required against the 10.3.9 SDK for Apple's context-sensitive
`vector` keyword, which `r_mesh.c`'s AltiVec lerp path uses. **It also silently
defeats `-mcpu=7400`'s Mach-O cpusubtype stamping**, emitting a generic
`ppc (ALL)` slice. Nothing warns, nothing fails, and the AltiVec path is intact
(12 vector instructions in `ref_gl.so`).

Why that is fatal rather than cosmetic: `ppc (ALL)` matches *every* PowerPC
host, so a fat of `[ppc ALL, ppc7400, ppc970]` mis-grades on a **G3 under Tiger
or Leopard and the binary refuses to exec**. Panther's laxer 2003 dyld accepts
it, so the bug hides on the machine most likely to be tested first. Proven on
hardware in the sister Half-Life port, whose v1.0.0 could not launch on the G3
under Tiger for exactly this reason. Caught here before release, 2026-07-25.

So `scripts/build.sh` asserts the expected subtype on all four artifacts after
every PPC build and re-stamps the 4-byte big-endian cpusubtype field at offset 8
of the thin Mach-O header where it drifted, then re-reads with `lipo` and fails
hard if the stamp did not take. **Never remove that block.** `make-dmg.sh`
re-checks with `lipo -archs` before packaging.

Note `file` prints subtype 9 as `ppc_650` on a modern host. That is a naming
quirk of the tool, not a bad stamp. Trust `lipo`.

The 10.3.9 SDK also forces **`-isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`**
on the G4 build: `r_mesh.c` includes `<altivec.h>`, which is a **compiler**
header, not an SDK one, and `-isysroot` hides it.

## Evidence that slice selection works

Positive control on the G3, 2026-07-25 (issue #3): swapping the *thin* `ppc7400`
`ref_gl.so` into the install makes the engine die with a null renderer vtable in
`CL_Frame`, so the fat's `ppc750` member is demonstrably what dyld grades on
that host. The shipped DMG then ran on the G3's 10.4 partition on the production
path at **21.0 fps**, identical to Panther's 21.0 from the same disk image.
Same-build A/B across the two partitions: **25.50 / 50.40 (Panther)** vs
**25.80 / 49.10 (Tiger)** at 1024x768 / 640x480. The OS costs the G3 nothing
measurable.

## Configurations built but not tested

Say so in the README rather than implying support:

- **A G4 on Panther** and **an Intel Mac on Snow Leopard** should both work, but
  neither exists in the fleet and neither has been run on hardware.

## What is not shipped

- **No `i386` slice.** 32-bit-only Intel Macs (2006 Core Solo / Core Duo) get
  nothing. There is no such machine here to build or test one on. The shipped
  `SDL.framework` does carry an i386 slice (ADR 0004); the engine does not.
- **No `arm64` slice.** See ADR 0003.

## Consequences

- One `.app` runs on Mac OS X 10.3.9 through modern macOS.
- Three PPC targets share one `-arch ppc` object tree on the build host,
  differing only by `-mcpu`, which is why PPC builds must never run in parallel
  on the same mini (ADR 0005).
- Every claim about a slice has to be shown with `lipo -archs` / `lipo -info`
  on the artifact, not inferred from the flags (ADR 0006).
