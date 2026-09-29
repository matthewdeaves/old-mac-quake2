# Deployment and game data

Bundle placement, pinned deploy tools, DMG installation and player data.
Build targets and compiler flags remain in `docs/BUILD.md`.
Sections: Deploy layout, Shared scripts, DMG install, Game data.

## Deploy layout

`scripts/deploy.sh <machine>` ships **one** thing: the universal `Quake2.app` from `build/q2-fat/`. A previous dual-mode design (per-target flat layout versus fat `.app`) had a foot-gun: both wrote to the same `~/Desktop/quake2/` with `rsync --delete`, so the wrong one wiped the `.app`. Per-target deploy is gone; `scripts/build.sh <target>` still exists for single-slice iteration but its output only feeds `build-fat.sh`.

Target install layout, `/Applications/Quake2/`:

```
Quake2.app/                 everything, incl. Contents/Resources/autoexec-*.cfg
ref_gl.so                   OUTSIDE the bundle, Q2 resolves these via basedir=.
q2ded
baseq2/game.so
baseq2/pak*.pak             the user's own data
```

`SDLMain.m` chdirs the process to the `.app`'s parent directory on a Finder launch, so `basedir=.` resolves there.

## Shared scripts

`deploy-dmg.sh` and `smoke-dmg.sh` are shared with the other ports (old-mac-build-host#96). This repo carries no real copy of `pick-build-host.sh`, `pick-bench-host.sh`, `deploy-dmg.sh`, `smoke-dmg.sh`, `bench-evidence.sh`, `bench-compare.sh`, `gui-precondition.sh` or `clear-launch-quarantine.sh`: build-host#105's pin model (ADR 0007 in old-mac-build-host). `shared-scripts.pin` (repo root) names the revision; `scripts/shared.sh <name>.sh [args...]` fetches and execs it from a sibling `../old-mac-build-host` checkout (`OLDMAC_BUILDHOST_REPO` overrides). `source-stamp.sh` stays a real copy: it is sourced, not exec'd. Quake II's own part is `scripts/dmg-port.conf` and `scripts/dmg-hooks.sh`.

**`pick-bench-host.sh`, `deploy-dmg.sh` and `smoke-dmg.sh` stay as thin, path-stable shims** at their old path, each `exec`ing through `shared.sh` (the two DMG scripts also resolve `DMG_PORT_CONF` and a real `dist/*.dmg` path before forwarding), because old-mac-build-host's generated Jenkins jobs invoke them by fixed path (build-host#119, halflife#49). Call these three exactly as in Commands; the pin indirection is invisible. The others have no fixed-path caller and are genuinely gone: reach them with `scripts/shared.sh <name>.sh [args...]`.

`bench-evidence.sh` needs an explicit `BENCH_ADAPTER` override every call: see `docs/BENCH.md`, Evidence bundles.

## DMG install

`deploy-dmg.sh` checks the DMG signature, SDL2 companion and all six slices first, then replaces only the runtime (`Quake2.app`, `ref_gl.so`, `q2ded`, `baseq2/game.so`) and md5-verifies it. The rest of `baseq2/` (paks, `players/`, a user `autoexec.cfg`) is never touched. No rollback copy is kept (fix forward, 2026-09-23); a bad release is replaced by a fixed one. `deploy.sh` updates a dev install the same way.

`rsync --delete` is scoped to the staged `Quake2.app` bundle. It never sweeps the install root or `baseq2/`, avoiding the historical deletion of player-model directories (crakhor, cyborg, female, male). The canonical cache for those files is `.game-data/baseq2/players/`.

## Game data

Canonical set lives on quicksilver at `~/Desktop/Quake 2/`; `deploy.sh` mirrors it. Required: `baseq2/pak0.pak` (184 MB), `pak1.pak` (13 MB, the 3.20 point release), `pak2.pak` (45 KB), `baseq2/players/`, `baseq2/video/`. Optional: `ctf/` (pak0 + pak1), `rogue/`, `xatrix/`. No game content is in this repo (ADR 0012).
