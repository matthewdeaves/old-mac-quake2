# 5. Cross-compile every slice on an Intel Lion mini: package the disk image on a Tiger G4

Date: 2026-08-20 (records decisions taken 2026-05-11 and 2026-05-31)
Status: accepted

## Context

No single machine can do the whole job. The 10.3.9 / 10.4u / 10.5 SDKs and the
`gcc-4.0` that goes with them exist only on the Intel Lion minis under
`/Developer/SDKs`. Old tools cannot read new formats and new tools cannot write
old ones, which decides where each step runs.

## Decision

**All four slices cross-compile on an Intel Lion mini. The release disk image is
packaged on a Tiger G4. The PowerPC machines are bench and deploy targets only.**

### Which mini is asked, never assumed

Two interchangeable hosts exist: **`mini-intel`** and **`mini-intel2`**, the same
Macmini2,1 on 10.7.5 with identical toolchains, so either builds any slice.
`scripts/build.sh` and `scripts/build-fat.sh` call
`scripts/pick-build-host.sh --acquire` and release on exit. `BUILD_HOST=<alias>`
pins one; `--status` shows both.

**Why the claim lives on the mini and not in the repo:** a per-checkout `flock`
cannot see a build another repo, agent or workstation started on the same box.
The picker locks `/tmp/.retro-build-lock` ON the host and also counts running
compiler processes as busy, so it detects builds started outside it entirely.
Both mechanisms are kept; `flock` still guards same-repo races.

### Never run PPC builds in parallel on the SAME mini

The three PPC targets rsync to the same `quake2/` directory there and share one
`-arch ppc` object tree, differing only by `-mcpu`. Concurrent runs race the
`.o` files and the binary ends up stamped with the *other* target's CPU subtype.
Symptom: the G3 binary becomes `ppc7400`, Panther loads it, then crashes during
NIB init on a 750.

`build.sh` takes a flock; `build-fat.sh` runs g3→g4→g5→lion strictly
sequentially and pins ONE claimed host for the whole run plus the `lipo`;
`build.sh` also `make clean`s before each slice so a stale `.o` from a different
`-mcpu` cannot leak. **Two builds on different minis are fine**, that is what
the second box is for.

### Multi-tenancy with the sister projects

`mini-intel` is shared with QuakeSpasm, Quake III and Half-Life. Isolation is by
separate upload directories and workstation-local artifacts:

| Resource | QuakeSpasm | Quake II (must) |
|---|---|---|
| rsync target on the mini | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` (top level) |
| local flock | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| local outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

Shared read-only: `/Developer/SDKs/MacOSX10.3.9.sdk`,
`/Developer/SDKs/MacOSX10.4u.sdk`, `/Developer/SDKs/MacOSX10.5.sdk`,
`/usr/bin/gcc-4.0`, `/usr/bin/clang`.

**Never modify anything under `/Developer/SDKs/` or the system toolchain.**
Reinstalling Xcode 3.2.6 + 2.5 from the vendored DMGs is a multi-hour recovery,
and the sister projects depend on the current install.

Tell-tale of accidental conflation: if `build.sh` rsyncs to `mini-intel:~/` with
no project prefix, or to `mini-intel:quakespasm/`, it overwrites QuakeSpasm's
source. `build.sh` hardcodes `mini-intel:quake2/` and asserts the path is
project-local before rsync.

Concurrent builds from different projects on one mini are safe given that
isolation. The only contention is CPU on a dual-core Core 2 Duo, so serial is
faster than 2x concurrent, but it is not a correctness question.

### The disk image is built on Tiger, not Lion and not the G3

Empirically tested 2026-05-31:

- **Lion's `hdiutil` cannot write a Panther-mountable image.** UDZO,
  uncompressed UDRO and `-layout SPUD` (Apple Partition Map) all report
  "no mountable file systems" on 10.3.9. **No `hdiutil` flag fixes it.**
- **A Tiger-built UDZO mounts on Panther and on everything newer.** Old-to-new
  compatibility holds, new-to-old does not. Tiger 10.4 is the oldest OS needed
  for the `hdiutil` step.
- **Not the 1999 Panther G3.** Its non-ECC RAM and 25-year-old disk are the
  flakiest hardware in the fleet and were the source of the single-byte
  corruption that shipped an illegal-instruction crash to every G4 (ADR 0006).

`DMG_HOST` defaults to the first reachable Tiger box, `quicksilver` then
`mini-g4`. The binaries are still built on Lion; `DMG_HOST` only runs the
`hdiutil` step on the staged tree.

## Alternatives rejected

**Build natively on the PowerPC machines.** They are the slowest hardware and the
machines under test; a build there consumes the thing being measured.

**Build on the modern orchestration box.** It carries none of these SDKs or
compilers.

**Hardcode one mini.** Wastes half the capacity and reintroduces the collision
the lock prevents.

## Consequences

- Nothing can be tested where it is built, so every PowerPC verification is a
  deploy-and-observe cycle on other hardware.
- A release needs three machines reachable: an Intel mini, the orchestration
  box, and a Tiger G4.
- Old-OS operational limits become the project's: Leopard's `sudo` is 1.6.x and
  has **no `-n` flag** (`sudo: illegal option -n`), so use plain
  `sudo /sbin/reboot` with a NOPASSWD sudoers entry; Leopard's `/bin/sh` lacks
  `seq`; there is no usable `pkill`, so kill by name with `killall`.
