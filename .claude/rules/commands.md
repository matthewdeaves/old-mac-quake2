---
paths:
  - "scripts/**"
---

## Commands

```sh
scripts/shared.sh pick-build-host.sh --status    # which Intel mini is free
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo, one pinned host
scripts/build.sh <g3|g4|g5|lion>                 # one slice, fast iteration only
scripts/deploy.sh <machine>                      # ships build/q2-fat
scripts/make-dmg.sh                              # → dist/, hdiutil step on a TIGER box
scripts/deploy-dmg.sh <machine> [ver]            # install/update from the image (shared, no rollback)
scripts/smoke-dmg.sh <machine>                   # production-config launch test (shared)
scripts/bench.sh <machine> <demo> <WxH> [runs]   # launches via scripts/q2-launch.sh
scripts/check-frames.sh <machine> [--update]     # is the PICTURE still correct
scripts/build-server-linux.sh [--arch aarch64]   # Linux q2ded, Debian 11 container
```

`BUILD_HOST=` pins a mini, `DMG_HOST=` the packaging box. Every other shared script (`pick-*`, `bench-evidence`, `bench-compare`, `gui-precondition`, `launch-game`, `qemu-vm`) is fetched at `shared-scripts.pin`'s revision: `scripts/shared.sh <name>.sh [args]`. Three stay as thin path-stable shims because build-host's Jenkins jobs call them by path: `pick-bench-host.sh`, `deploy-dmg.sh`, `smoke-dmg.sh`. See `docs/BUILD.md` for the `BENCH_ADAPTER`/`DMG_PORT_CONF` overrides.

**Engine start/stop**: `bench.sh`, `screenshot.sh`, `join-smoke.sh` and `vm-frame-check.sh` source `scripts/q2-launch.sh` (`q2_launch`, `q2_stop`, `q2_pretidy`), which wraps the shared `launch-game.sh`. It refuses while any game runs on the host. No bare `&` or `killall` in new scripts.

**Smoke, the imac-g5 bench and release fan-out run via Jenkins** (jobs `smoke-quake2-<machine>`, `bench-quake2-imac-g5`, `release-fanout-quake2`, same scripts and lock; `BENCH_CSV`/`BENCH_RAW_DIR` redirected). Invocation and job list: `docs/JOBS.md`. Fan-out needs a DMG already in `dist/`.
