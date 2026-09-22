# Installed RC2 acceptance

Installed `Quake2-OldMac-2026-09-22-shadows-rc2.dmg` through the occupied-install
updater. Previous installation retained at the named rollback in the deploy log.
Game data preserved; no public release was published.

Jenkins smoke-quake2-mini-sl build3 SUCCESS. Normal LaunchServices startup
selected bloom and projected-shadow auto defaults on NVIDIA GeForce 9400.
The native desktop capture was 1920x1080 even though the requested custom size
readback remains 1024x768. With the normal gl_swapinterval1 setting, demo1
reported 29.9 fps. Do not confuse this with uncapped floor measurements.

Whole installed candidate, demo2 native1920x1080, uncapped benchmark with no
graphics-feature overrides: 46.0/44.5/45.2 fps, warm44.85. Readbacks confirm
stencilshadow1, combinedclear1 and bloom_fastrestore1, with bloom1 and requested
MSAA2. Installed frame03 was inspected and shows projected shadows and bloom.
Normal player config was restored after benchmark/capture; matching hashes
are retained. All game processes exited.

The preserved saved config still contains stencilshadow0. That is not the
effective launch setting: the bundled generic profile requests -1, and the
renderer resolves it to projected shadows on this GPU at every normal startup.
Both the smoke and installed benchmark logs contain that auto-selection message.
The current bench/screenshot scripts do not pass -noarchautoexec by default;
their command lines override the measurement settings while retaining bundle
feature selection. Older ADR descriptions of that flag are stale.

Before production smoke, s_volume0 and s_initsound0 were explicitly set in the
player config, with its original retained under the silent-smoke backup path.
The production log confirms sound was not initialized. Benchmark and screenshot
scripts also disable sound initialization. System mute readback is unavailable
on this host, so engine-side silence is the verified protection.

Installed engine MD5: 55dc759b67f770a1f1f0ede4e3636b82
Installed renderer MD5: dcfde8e72664968edd16f15f298d785b

G3 remains on its previous user-tested RC1 installation, untouched. This
acceptance covers Intel Snow Leopard, not a new G3/G4/G5 runtime test.
