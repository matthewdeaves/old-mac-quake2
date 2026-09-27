---
paths:
  - "scripts/**"
---

## Locking: two pickers, claimed differently

This repo is one of seven worked on together, one board:
<https://github.com/users/matthewdeaves/projects/8>. The hardware lock is a
directory on the target host, shared with every repo/agent/workstation —
check `scripts/pick-bench-host.sh --status` before assuming a box is idle,
never work around a busy one.

`scripts/pick-bench-host.sh` is a thin shim kept at this fixed path because
old-mac-build-host's generated Jenkins jobs call it there (build-host#119,
halflife#49). The rest of the shared picker/build/deploy/smoke surface is
fetched on demand via `scripts/shared.sh <name>.sh [args...]` at
`shared-scripts.pin`'s revision (build-host#105) — `pick-build-host.sh` has
no such caller and is reached only that way.

Seven scripts re-exec themselves under `pick-bench-host.sh --run` (ties the
lock to the invocation, released however it ends): `bench.sh`, `deploy.sh`,
`deploy-dmg.sh`, `make-dmg.sh`, `screenshot.sh`, `smoke-dmg.sh`,
`tidy-quicksilver.sh`. `build.sh`/`build-fat.sh` instead claim via
`pick-build-host.sh --acquire` and release on an EXIT trap (that picker has
no `--run` mode). `parallel-bench.sh` claims nothing itself — each leg is its
own `bench.sh` call, and its reachability probe is deliberately left
unclaimed. `build-arm64.sh`/`build-server-linux.sh` touch no fleet machine at
all (workstation + Docker only).

`BENCH_NO_LOCK=1` is for debugging the picker itself, not an escape hatch for
a busy machine: `--run` honours it (loudly, on stderr); `--acquire` always
claims regardless, only warning. The build picker never honours it.

## Cross-repo ticket labels

Four labels, same meaning in every repo: `from:infra` (raised by the server
side for a port to act on), `from:port` (raised by a port for another repo),
`needs-measurement` (the claim has no number or repro behind it yet — not
worked until a human or a measurement moves it), `cross-port` (affects more
than one port — file sibling issues, don't assume a fix transfers).

File cross-repo work as an issue **without** `--project` (that flag leaves
Status null — no column at all, not Triage, and looks like unraised work),
then `../retro-agents/bin/board-add.sh <repo>#<n>` to actually place it in
Triage.
