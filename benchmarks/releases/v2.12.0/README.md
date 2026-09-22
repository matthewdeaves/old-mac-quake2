# v2.12.0 release evidence, 2026-09-22

## Artifact

- `dist/Quake2-OldMac-v2.12.0.dmg`, SHA256
  `e2cd2fd1342a13a8ec77af4178601073d9834c9f2f05314cda598dd3487d2031`.
  Packaged on mini-g4 (Tiger), `logs/package.log`.
- Built from engine source `c04ad992` (source stamp
  `92213e21568bda62b2f7acca69065c789607d85c96d5b6598cc142b7929ab6ff`).
  Commits after it up to the tag change only scripts and evidence, not
  engine source.
- Bundle version `5.11-oldmac-v2.12.0`. Six slices on each of `quake2`,
  `ref_gl.so` and `baseq2/game.so` (numeric `otool -h`, `scripts/macho-archs.sh`):
  `ppc750 ppc7400 ppc970 x86_64 i386 arm64`.
- MD5 inside the image, ad-hoc signed: `quake2` `2f7874ddbd9f78498d35dce1b107aa38`,
  `ref_gl.so` `b048e080987ec664bb6ae23831ed4ee7`, `game.so`
  `fec331f2a3c42cdcaed3c20a0c7c115f`, `q2ded` `5624f403ec42c49cbab95d945db7add7`.

## Install and smoke

Each host was upgraded in place from the image by `update-install-tree.sh`,
keeping a named rollback under `~/oldmac/quake2/rollbacks/`. After install,
each host read back engine MD5 `2f7874dd…` and version `5.11-oldmac-v2.12.0`.
Smokes use the production config, sound disabled, system output muted.

| Host | OS | GPU | Slice | Smoke | Result |
| --- | --- | --- | --- | --- | --- |
| yosemite | 10.3.9 Panther | ATI Rage 128 | ppc750 | Jenkins `smoke-quake2-g3` #5 | PASS, new game started (no argv on this OS, #35) |
| mini-g4 | 10.4.11 Tiger | ATI Radeon 9200 | ppc7400 | Jenkins `smoke-quake2-mini-g4` #3 | PASS, new game started (#35) |
| imac-g5 | 10.5.8 Leopard | ATI Radeon 9600 | ppc970 | Jenkins `smoke-quake2-imac-g5` #5 | PASS, native 1440x900, new game started (#35) |
| mini-sl | 10.6.8 Snow Leopard | NVIDIA GeForce 9400 | x86_64 | Jenkins `smoke-quake2-mini-sl` #4 | PASS, demo1 29.8 fps, vsync on |
| imac-2019 | 15.7.9 Sequoia | AMD Radeon Pro 580X | x86_64 | Jenkins `smoke-quake2-mini-intel` #5 (FLEET_HOST imac-2019) | PASS, demo1 76.3 fps at 1920x1080 |
| workstation | 26.6.2 | Apple M5 | arm64 | `scripts/smoke-dmg.sh workstation` | PASS, demo1 59.4 fps, vsync on |

Smoke fps is a vsync-on production launch, not a benchmark.

Two smokes that failed before the game launched were re-run, and neither is
counted: imac-2019 #4 (a Jenkins git fetch raced a concurrent job on the same
agent checkout) and imac-g5 #4 (the picker reported the host briefly busy).

The workstation has no remote `--update` path in `deploy-dmg.sh`, which tried
to SSH to a host named `workstation` and refused before changing anything.
It was installed with the same `update-install-tree.sh` primitive run
locally under a `pick-bench-host.sh --run workstation` claim,
`logs/deploy-workstation.log`. Afterwards, the user's local M5 sound-on lines
were re-appended to the bundled `autoexec-controls.cfg`, and the second smoke
passed with them in place.

## Not covered

- yosemite-tiger (G3 on Tiger): not booted, since only one partition runs at a time.
- mini-intel (GMA 950, Lion): off. mini-intel2 was building for another repo.
- sawtooth, quicksilver and the G5 towers: off.
- i386: never tested on hardware (unchanged).
