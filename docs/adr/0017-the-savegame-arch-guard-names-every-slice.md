# 17. The savegame arch guard names every slice, and old PowerPC saves break

Date: 2026-08-22
Status: accepted

## Context

`yquake2/src/game/savegame/savegame.c` writes four identification strings into
every savegame and refuses to load one whose strings do not match the running
build. Upstream's reason for the arch string is blunt:

> This macros are used to prohibit loading of savegames created on other
> systems or architectures. This will crash q2 in spectacular ways

The string came from a preprocessor block that only knew `__i386__`,
`__x86_64__`, `__sparc__` and `__ia64__`. Everything else fell through to
`"unknown"`.

Measured on the shipped `Quake2-OldMac-v2.7.4.dmg`, reading `baseq2/game.so`:

| slice | arch string |
|---|---|
| ppc750 | `unknown` |
| ppc7400 | `unknown` |
| ppc970 | `unknown` |
| x86_64 | `amd64` |
| i386 | `i386` |
| arm64 | `unknown` |

So the guard could not tell a PowerPC save from an Apple Silicon one. That
pairing crosses **both** byte order and word size, which is the case the guard
exists to catch.

Three PowerPC slices sharing one string is harmless: all three are 32-bit
`-arch ppc` and share an ABI.

## Decision

**Name every architecture we build, and accept that old PowerPC and Apple
Silicon saves stop loading.**

`__aarch64__`/`__arm64__` give `arm64`, `__ppc__`/`__POWERPC__` give `ppc`, and
`__ppc64__` gives `ppc64` for a slice we do not currently build. Measured on the
rebuilt fat binary, all six slices now self-identify:

```
ppc750 ppc   ppc7400 ppc   ppc970 ppc   x86_64 amd64   i386 i386   arm64 arm64
```

The same fix is applied to `CPUSTRING` in `src/common/header/common.h`. That
string is cosmetic, it only prints in the banner and the version string, but it
had the identical defect from the identical cause. Leaving one of the two wrong
is how the original report came to measure the banner and describe it as the
guard.

**The breakage is chosen, not overlooked.** PowerPC and arm64 slices previously
wrote `unknown`; they now write `ppc` or `arm64`, and the guard rejects the
mismatch. Intel saves are unaffected because `amd64` and `i386` did not change.

Accepting `unknown` on read would preserve those saves and was rejected: every
PowerPC and arm64 slice wrote the same `unknown`, so a rule that accepts it
cannot tell a G4 save from an Apple Silicon one. That is the hole this ADR
closes.

The arm64 exposure was small in practice — that slice first shipped on
2026-08-20, two days before this change (`57b4b317`).

## Per-slice defines, not a build-system variable

The 8.70 server tree (`yquake2-server/`) solves this differently, with a
`YQ2ARCH` macro the Makefile derives from `uname -m`. **That mechanism does not
exist in the 5.11 client tree and must not be copied into it.**

`uname -m` reports the build machine, which is correct for a native build and
wrong for a cross-compiled fat binary. The preprocessor block is correct by
construction instead: each slice is a separate compiler invocation with its own
predefined macros, so each one evaluates its own case.

Both trees have a file at `src/game/savegame/savegame.c`. They are not the same
file and do not share this mechanism.

## Consequences

- A savegame written on any PowerPC Mac in the fleet will not load after this
  change. Deleting it is the remedy; there is no migration.
- The guard now blocks a PowerPC/arm64 cross-load, which was its purpose.
- Whether such a cross-load would have crashed was never measured, and is now
  moot. It is recorded as unmeasured rather than as safe.
- Reading these strings back out of a binary needs `strings -n 3`. `ppc` is
  three characters and `strings` defaults to a four-character minimum, so a
  plain `strings` returns nothing and looks exactly like a failed build.
