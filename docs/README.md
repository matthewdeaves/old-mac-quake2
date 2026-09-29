# Documentation index

Task guides and reference documents for this repository.
Start with the task map in `CLAUDE.md`; open a reference only when that task needs it.
History lookup uses a ticket or date in the active ledger, then `docs/archive/`.

## Root references

- [BUGFIXES.md](../BUGFIXES.md)
- [MISTAKES.md](../MISTAKES.md)
- [README.md](../README.md)

## Task guides and topic references

- [BENCH-PROVENANCE.md](BENCH-PROVENANCE.md): Bench row provenance: what a results.csv row cannot say
- [BENCH.md](BENCH.md): Benchmarking and smoke testing
- [BUILD.md](BUILD.md): Build: deploy and package
- [CAUSTICS.md](CAUSTICS.md): Tuning the caustic look (`gl_caustics`)
- [CONFIG.md](CONFIG.md): Runtime config reference
- [DEPLOY.md](DEPLOY.md): Deployment and game data
- [FEATURES.md](FEATURES.md): Feature inventory
- [HARDWARE.md](HARDWARE.md): Hardware targets and hazards
- [HD_PACK.md](HD_PACK.md): HD texture pack: install guide
- [JOBS.md](JOBS.md): Quake II fleet operations as job definitions
- [LOCKS.md](LOCKS.md): Locking: two pickers
- [OPERATIONS.md](OPERATIONS.md): Commands
- [REFACTOR-HANDOFF.md](REFACTOR-HANDOFF.md): Renderer refactor candidate
- [RELEASE.md](RELEASE.md): Release inputs
- [STATUS.md](STATUS.md): Status
- [SUPPORT.md](SUPPORT.md): Engine facts
- [TESTS.md](TESTS.md): Test entry points
- [TICKETS.md](TICKETS.md): Ticket references
- [VM-TIGER.md](VM-TIGER.md): Tiger QEMU visual checks
- [WATCHLINK.md](WATCHLINK.md): watchlink: live player-state UDP feed
- [adr/0001-four-slices-graded-by-cpu-subtype.md](adr/0001-four-slices-graded-by-cpu-subtype.md): 1. Four slices: graded by CPU subtype, each stamped exactly
- [adr/0002-the-engine-is-pinned-at-yquake2-5-11.md](adr/0002-the-engine-is-pinned-at-yquake2-5-11.md): 2. The engine is pinned at yquake2 5.11, and that means SDL 1.2
- [adr/0003-arm64-is-a-separate-decision-from-an-engine-bump.md](adr/0003-arm64-is-a-separate-decision-from-an-engine-bump.md): 3. arm64 is a separate decision from an engine bump
- [adr/0004-the-fat-sdl-framework-carries-a-ppc970-leopard-slice.md](adr/0004-the-fat-sdl-framework-carries-a-ppc970-leopard-slice.md): 4. The fat SDL 1.2 framework is reused whole: with a dedicated ppc970 Leopard slice
- [adr/0005-cross-compile-on-lion-package-the-dmg-on-tiger.md](adr/0005-cross-compile-on-lion-package-the-dmg-on-tiger.md): 5. Cross-compile every slice on an Intel Lion mini: package the disk image on a Tiger G4
- [adr/0006-never-trust-exit-zero-verify-the-bytes-that-ship.md](adr/0006-never-trust-exit-zero-verify-the-bytes-that-ship.md): 6. Never trust exit 0: verify the artifact, and verify the bytes that ship
- [adr/0007-bundle-config-is-three-layers-applied-before-video-init.md](adr/0007-bundle-config-is-three-layers-applied-before-video-init.md): 7. Bundle config is three layers: applied before the renderer initialises
- [adr/0008-on-the-imac-g5-fullscreen-is-a-capture-never-a-mode-switch.md](adr/0008-on-the-imac-g5-fullscreen-is-a-capture-never-a-mode-switch.md): 8. On the iMac G5: fullscreen is a same-mode capture, never a mode switch
- [adr/0009-a-smoke-test-is-a-demo-run-that-auto-exits.md](adr/0009-a-smoke-test-is-a-demo-run-that-auto-exits.md): 9. A smoke test is a demo run that auto-exits, and a benchmark states its conditions
- [adr/0010-every-per-machine-visual-default-is-an-ab-on-that-machine.md](adr/0010-every-per-machine-visual-default-is-an-ab-on-that-machine.md): 10. Every per-machine visual default is an A/B on that machine
- [adr/0011-the-linux-dedicated-server-ships-from-the-same-tree.md](adr/0011-the-linux-dedicated-server-ships-from-the-same-tree.md): 11. The Linux dedicated server ships from the same tree, and is firewalled by allowlist
- [adr/0012-we-ship-code-and-generated-art-not-game-content.md](adr/0012-we-ship-code-and-generated-art-not-game-content.md): 12. We ship code and generated art, not game content
- [adr/0013-the-gl-1-4-gate-is-a-version-string-test-and-the-g3-passes-without-it.md](adr/0013-the-gl-1-4-gate-is-a-version-string-test-and-the-g3-passes-without-it.md): 13. The GL 1.4 gate is a version-string test, and the G3 runs fine without it
- [adr/0014-the-engine-is-arm64-clean-only-sdl-1-2-is-not.md](adr/0014-the-engine-is-arm64-clean-only-sdl-1-2-is-not.md): 14. The engine is arm64-clean. Only SDL 1.2 is not.
- [adr/0015-the-arm64-slice-ships-sdl12-compat-over-an-sdl2-we-build.md](adr/0015-the-arm64-slice-ships-sdl12-compat-over-an-sdl2-we-build.md): 15. The arm64 slice ships sdl12-compat over an SDL2 we build
- [adr/0016-the-linux-server-builds-from-a-newer-engine-than-the-mac-client.md](adr/0016-the-linux-server-builds-from-a-newer-engine-than-the-mac-client.md): 16. The Linux server builds from a newer engine than the Mac client
- [adr/0017-the-savegame-arch-guard-names-every-slice.md](adr/0017-the-savegame-arch-guard-names-every-slice.md): 17. The savegame arch guard names every slice, and old PowerPC saves break
- [adr/0018-claude-md-is-not-subscribed-to-the-shared-block-sync.md](adr/0018-claude-md-is-not-subscribed-to-the-shared-block-sync.md): 0018. CLAUDE.md is not subscribed to the shared block sync
- [mistakes/altivec.md](mistakes/altivec.md): Mistakes: AltiVec
- [mistakes/assessed-not-worth-doing.md](mistakes/assessed-not-worth-doing.md): Assessed and not worth doing
- [mistakes/build-packaging-deploy.md](mistakes/build-packaging-deploy.md): Mistakes: build, packaging and deploy
- [mistakes/dynamic-lights-geforce2.md](mistakes/dynamic-lights-geforce2.md): Mistakes: dynamic lights on the GeForce2 MX
- [mistakes/renderer-features.md](mistakes/renderer-features.md): Mistakes: renderer features
- [mistakes/testing-build-scripts.md](mistakes/testing-build-scripts.md): Mistakes: testing build scripts
- [mistakes/video-init-fullscreen.md](mistakes/video-init-fullscreen.md): Mistakes: video init and the fullscreen path
- [mistakes/watch-items.md](mistakes/watch-items.md): Watch items with no recorded failure yet

## History archive

Older and superseded accounts: [archive/](archive/). Search by ticket or date.
