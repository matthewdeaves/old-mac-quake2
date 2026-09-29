# Release inputs

Fleet release procedure governs promotion. This page maps the Quake II inputs.

## Package and verify
`scripts/make-dmg.sh` packages on a Tiger G4. Packaging constraints and the one-byte G3 corruption story are in `docs/adr/0005-cross-compile-on-lion-package-the-dmg-on-tiger.md`.
Build verification is in `docs/adr/0006-never-trust-exit-zero-verify-the-bytes-that-ship.md`; smoke coverage in `docs/BENCH.md`.

## Evidence and state
`docs/STATUS.md` points to release state; `benchmarks/releases/` holds release evidence. Older releases: `docs/archive/RELEASE-HISTORY.md`. `docs/JOBS.md` describes release fan-out, which requires a DMG already in `dist/`.
