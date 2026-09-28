# Quake II old-Mac port

Quake II on yquake2 5.11 as ONE fat PowerPC + Intel app, from a single `Quake2.app`, plus a Linux dedicated server from the same tree.

Sister project `~/quakespasm/` owns the shared infrastructure (SSH config, toolchain, vendored prerequisites, the fat SDL framework, host tooling). **Reuse it, do not re-invent it.**

All builds and CI are centralized on `old-mac-build-host`. There are no local Jenkinsfiles or CI build scripts in this repository.

## Hard traps

Can't be found in 30 seconds; violating one is expensive or irreversible.

- `-faltivec` silently defeats `-mcpu=7400` cpusubtype stamping; `build.sh` re-stamps and asserts after every PPC build — never remove that block. A generic `ppc (ALL)` fat member makes G3/Panther refuse to exec.
- Never run two PPC builds on the same build mini at once (shared `-arch ppc` object tree races).
- Build the release DMG only on a Tiger G4 — never Lion (its `hdiutil` can't write a Panther-mountable image) and never the G3 (it once flipped a byte and shipped a crash fleet-wide).
- Never trust "done"/exit 0 for a build: verify with `lipo -archs`/`otool`, md5 the bytes at the last hop. PPC builds are not byte-reproducible (~138 bytes); only compare artifacts from the same run.
- iMac G5: a non-native fullscreen mode SWITCH hard-hangs the whole OS (Radeon 9600 Leopard driver) — physical power button only, no SSH. Never bypass the guards (`vid_desktopfullscreen`, `GLimp_ForceDesktopFullscreen()`, `bench.sh`'s refusal) or trigger one remotely.
- A green check is not a correct picture: only `check-frames.sh` looks at an image. AltiVec `R_LerpVerts` once shipped a warped-model regression that read as a +4.3% fps win (issue #26). References live in `tests/frames/`, never `docs/screenshots/` (a curated gallery that deletes exactly what a correctness check needs).
- `yosemite` / `yosemite-tiger` are ONE machine, two OS partitions, only one booted at a time — never assume both are up.
- `qemu-tiger3d` iteration: `scripts/shared.sh qemu-vm.sh {up|down|status|doctor}` to manage the VM itself, `scripts/vm-frame-check.sh [out.png]` for a host-side gameplay frame capture — same picker claim/release as every other Mac.
- Never swap a test build into `/Applications/<Game>/` (no `.bak` copy either, even temporarily) — POLICY.md: that dir is release-build-and-data only on every Mac. Run a one-off test build from its own directory under `~/oldmac/` on the target, or point `basedir` at it.
- This repo is PUBLIC. Never copy addresses, key material, tunnel tokens or `.env` content out of `retro-server-infra` into this repo, in code, docs or commit messages.

## Documentation Router

Detailed reference material lives in `.claude/rules/*.md` and loads automatically when a matching file is touched (`paths:` frontmatter) — no need to read it ahead of time.

- **[.claude/rules/commands.md](.claude/rules/commands.md)** (`scripts/**`): compiling, deploying, benchmarking, generating a DMG.
- **[.claude/rules/facts.md](.claude/rules/facts.md)** (`scripts/**`, `yquake2/**`): engine/build constraints beyond the hard traps above (slice table, arm64 oddities, config layering, smoke-test definition, playability floor).
- **[.claude/rules/legacy-mac-hardware.md](.claude/rules/legacy-mac-hardware.md)** (`scripts/**`, `docs/**`): the hardware fleet table (CPU/GPU/OS/slice per machine).
- **[.claude/rules/ticketing-workflow.md](.claude/rules/ticketing-workflow.md)** (`scripts/**`): the two hardware-lock pickers and which scripts claim which way.
- **[.claude/rules/read-on-demand.md](.claude/rules/read-on-demand.md)** (`docs/**`): pointers into `docs/` and `server/`.

## Architecture Decision Records (ADRs)

Project reasoning, rejected alternatives, and historical decisions live in `docs/adr/`. Settled negatives and "do not do this" examples live in `MISTAKES.md`.
