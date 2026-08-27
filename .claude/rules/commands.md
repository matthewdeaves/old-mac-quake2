## Commands

```sh
scripts/pick-build-host.sh --status              # which Intel mini is free
scripts/build-fat.sh                             # g3→g4→g5→lion + lipo, one pinned host
scripts/build.sh <g3|g4|g5|lion>                 # one slice, for fast iteration only
scripts/deploy.sh <machine>                      # ships build/q2-fat
scripts/make-dmg.sh                              # → dist/, hdiutil step on a TIGER box
scripts/deploy-dmg.sh <machine>                  # install from the image, as a human does
scripts/smoke-dmg.sh <machine>                   # production-config launch test
scripts/bench.sh <machine> <demo> <WxH> [runs]
scripts/check-frames.sh <machine> [--update]     # is the PICTURE still correct
scripts/build-server-linux.sh [--arch aarch64]   # Linux q2ded, in a Debian 11 container
```

`BUILD_HOST=` pins a mini, `DMG_HOST=` the packaging box.

**Smoke and the imac-g5 bench run via Jenkins now, not by hand** (user
policy 2026-08-23, `retro-agents/briefs/_shared.md`): jobs
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
