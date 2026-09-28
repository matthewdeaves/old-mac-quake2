# Quake II old-Mac port

yquake2 5.11 as one fat PowerPC + Intel `Quake2.app` (SDL 1.2, one renderer) plus a Linux dedicated server, from one tree. Builds, CI and shared tooling live in `old-mac-build-host`; reach them with `scripts/shared.sh <name>.sh` (pinned in `shared-scripts.pin`). This repo is PUBLIC: no addresses, keys or `.env` content from retro-server-infra.

## Traps (each cost a real incident)
- `-faltivec` defeats `-mcpu=7400` stamping; `build.sh` re-stamps and asserts. Never remove it (ADR 0001).
- Release DMG only on a Tiger G4, never Lion or the G3 (ADR 0005).
- iMac G5: a non-native fullscreen mode switch hangs the whole OS. Never bypass the guards (ADR 0008).
- A green check is not a correct picture: only `scripts/check-frames.sh` looks at an image (issue #26).
- Engine start/stop goes through `scripts/q2-launch.sh` (shared `launch-game.sh`, one game per host), never a bare `&`.
- `qemu-tiger3d` loop: `scripts/shared.sh qemu-vm.sh {up|down|status|doctor}`, `scripts/vm-frame-check.sh [out.png]`.
- `scripts/source-stamp.sh` is canonical in build-host; edit `source-stamp-excludes.sh` only.
- Never run two PPC builds on one mini; never trust exit 0 (`lipo -archs`, md5 the shipped bytes).

## Where to look
- Build, deploy, bench, smoke commands: `.claude/rules/commands.md` (loads with `scripts/**`)
- Engine and build facts: `.claude/rules/engine-facts.md`, `.claude/rules/build-facts.md`
- Fleet hardware table: `.claude/rules/legacy-mac-hardware.md`
- Locks and pickers: `.claude/rules/ticketing-workflow.md`
- Why a decision was made: `docs/adr/` (`grep -n '^# ' docs/adr/*.md`)
- Tried and rejected ideas: `MISTAKES.md` (index) → `docs/mistakes/<topic>.md`, before any "easy, zero-risk" idea
- Fix history: `grep -n '#NNN' BUGFIXES.md`; older releases and handoffs in `docs/archive/`
- Build flags, layout, game data: `docs/BUILD.md`; harness: `docs/BENCH.md` (results provenance: `docs/BENCH-PROVENANCE.md`); cvars: `docs/CONFIG.md`; shipped features: `docs/FEATURES.md`; caustics: `docs/CAUSTICS.md`
- Release state: `docs/STATUS.md`; CI jobs: `docs/JOBS.md`; server: `server/README.md`; refactor cvars: `docs/REFACTOR-HANDOFF.md`
- HD pack: `docs/HD_PACK.md`; Watch feed: `docs/WATCHLINK.md`; VM: `docs/VM-TIGER.md`
- Public overview: `README.md`; benchmark evidence: `benchmarks/`
