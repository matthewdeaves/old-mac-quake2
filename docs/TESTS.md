# Test entry points

## Local checks
Run `tests/test-repo.sh` for repository contracts, `tests/test-macho-archs.sh` for architecture inspection, and `tests/test-renderer-refactor.sh` for renderer regressions.

## Runtime checks
Use `scripts/check-frames.sh <machine> [--update]` for deterministic image comparisons. The VM host-frame check is in `docs/VM-TIGER.md`; smoke and benchmark procedures are in `docs/BENCH.md`.
