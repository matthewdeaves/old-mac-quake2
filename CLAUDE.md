# Quake II old-Mac port

yquake2 5.11 supplies the Mac client; `yquake2-server/` supplies the newer Linux server. Declared slices and support: `docs/SUPPORT.md`. This repo is PUBLIC: no addresses, keys or `.env` content from retro-server-infra. Shared tooling lives in `old-mac-build-host`: `scripts/shared.sh <name>.sh` (pinned in `shared-scripts.pin`).

## Traps
- Never remove `-faltivec`; `build.sh` re-stamps `-mcpu=7400` and asserts (docs/adr/0001-four-slices-graded-by-cpu-subtype.md).
- Package release DMGs on a Tiger G4, never Lion or the G3 (docs/adr/0005-cross-compile-on-lion-package-the-dmg-on-tiger.md).
- Keep the iMac G5 at native fullscreen; a mode switch hangs the OS (docs/adr/0008-on-the-imac-g5-fullscreen-is-a-capture-never-a-mode-switch.md).
- Check the picture with `scripts/check-frames.sh`; FPS hid warped models (docs/mistakes/altivec.md).
- Start and stop engines through `scripts/q2-launch.sh`, never a bare `&` (docs/OPERATIONS.md).
- Never run two PPC builds on one mini; never trust exit 0: `lipo -archs`, md5 the shipped bytes (docs/adr/0006-never-trust-exit-zero-verify-the-bytes-that-ship.md).
- `scripts/source-stamp.sh` is canonical in build-host; edit `source-stamp-excludes.sh` only.

## Where to look
- Docs → `docs/README.md`
- Build → `docs/BUILD.md`
- Deploy → `docs/DEPLOY.md`
- Smoke, bench → `docs/BENCH.md`
- Tests → `docs/TESTS.md`
- Release → `docs/RELEASE.md`
- Locks, pickers → `docs/LOCKS.md`
- Machines → `docs/HARDWARE.md`
- Tickets → `docs/TICKETS.md`
- VM (`qemu-tiger3d`; `scripts/vm-frame-check.sh`) → `docs/VM-TIGER.md`
- Why decided → `docs/adr/`; rejected ideas → `MISTAKES.md`, before any "easy" idea
- Fix history → `grep -n '#NNN' BUGFIXES.md`; older in `docs/archive/`
