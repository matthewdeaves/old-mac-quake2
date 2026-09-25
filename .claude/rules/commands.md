## Commands

```sh
scripts/shared.sh pick-build-host.sh --status    # which Intel mini is free (see below)
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo, one pinned host
scripts/build.sh <g3|g4|g5|lion>                 # one slice, for fast iteration only
scripts/deploy.sh <machine>                      # ships build/q2-fat
scripts/make-dmg.sh                              # → dist/, hdiutil step on a TIGER box
scripts/deploy-dmg.sh <machine> [ver]            # install/update from the image; shared (#96), no rollback
scripts/smoke-dmg.sh <machine>                   # production-config launch test; shared (#96)
scripts/bench.sh <machine> <demo> <WxH> [runs]
scripts/check-frames.sh <machine> [--update]     # is the PICTURE still correct
scripts/build-server-linux.sh [--arch aarch64]   # Linux q2ded, in a Debian 11 container
```

`BUILD_HOST=` pins a mini, `DMG_HOST=` the packaging box. Since the #91/#105
pin migration, none of `pick-build-host.sh`, `pick-bench-host.sh`,
`deploy-dmg.sh`, `smoke-dmg.sh`, `bench-evidence.sh`, `bench-compare.sh`,
`gui-precondition.sh` or `clear-launch-quarantine.sh` are copies any more —
they're fetched on demand from `shared-scripts.pin`'s revision via
`scripts/shared.sh <name>.sh [args...]`. **Three are kept as thin,
path-stable shim files at their old path** (`pick-bench-host.sh`,
`deploy-dmg.sh`, `smoke-dmg.sh` — each just `exec`s through `shared.sh`)
because old-mac-build-host's generated Jenkins jobs invoke them by fixed
path (build-host#119, halflife#49's fix for the gap this repo hit first) —
call these three exactly as before, the indirection is invisible. The other
five (`pick-build-host.sh`, `bench-evidence.sh`, `bench-compare.sh`,
`gui-precondition.sh`, `clear-launch-quarantine.sh`) have no such caller and
are genuinely gone — reach them with `scripts/shared.sh <name>.sh [args...]`
(pick-build-host.sh --status: `scripts/shared.sh pick-build-host.sh
--status`). See docs/BUILD.md for the `BENCH_ADAPTER`/`DMG_PORT_CONF`
overrides two of them still need even from inside `shared.sh`.

**Smoke and the imac-g5 bench run via Jenkins now, not by hand** (user
policy 2026-08-23, `retro-agents/POLICY.md`): jobs
`smoke-quake2-<machine>` (every smoke-capable node) and
`bench-quake2-imac-g5` are proven equivalents of the scripts above (same
scripts, same lock; `BENCH_CSV`/`BENCH_RAW_DIR` redirected so tracked
results are untouched). Invoke:

```sh
ssh u25 'PW=$(cat ~/jenkins/home/secrets/initialAdminPassword); java -jar ~/jenkins/jenkins-cli.jar -s http://10.188.1.19:8080 -auth admin:$PW build smoke-quake2-<machine> -p FLEET_HOST=<machine> -s -v'
```

`release-fanout-quake2` is also proven: deploy-dmg + smoke-dmg across a
machine list (`FLEET_HOST` = space-separated list; default covers the
smoke-capable machines), skipping busy/off machines rather than failing.
It needs a DMG already in `dist/` — it does not build one. Use it for
release-candidate rollout instead of looping `deploy-dmg.sh` /
`smoke-dmg.sh` by hand.

Benches on other machines still use `bench.sh` directly until their jobs
are proven.
