## Locking: two pickers

The hardware lock is a directory on the target host, shared by every repo, agent and workstation. Check `scripts/pick-bench-host.sh --status` before assuming a box is idle; never work around a busy one.

- `bench.sh`, `deploy.sh`, `deploy-dmg.sh`, `make-dmg.sh`, `screenshot.sh`, `smoke-dmg.sh`, `tidy-quicksilver.sh` re-exec under `pick-bench-host.sh --run` (lock released however they end).
- `build.sh`/`build-fat.sh` claim via `pick-build-host.sh --acquire` and release on an EXIT trap (no `--run` mode).
- `parallel-bench.sh` claims nothing itself; each leg is its own `bench.sh` call.
- `build-arm64.sh`/`build-server-linux.sh` touch no fleet machine.
- `BENCH_NO_LOCK=1` is for debugging the picker, not for getting past a busy machine. To release a stale claim, export `BENCH_LOCK_CLAIM=<claim id from --status>`.

Cross-repo tickets carry labels `from:infra`, `from:port`, `needs-measurement`, `cross-port`.
