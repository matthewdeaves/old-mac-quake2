# v2.13.0 release evidence

- `dist/Quake2-OldMac-v2.13.0.dmg`, SHA256
  `1357d187c588a659c4557dbfd8fcc013dd2a22dec16cc62925ff8ec9081ed573`
  (7,022,498 bytes). Packaged on mini-g4 (Tiger G4).
- Tag `v2.13.0` on cf3d518a, which is what ships: engine source 40c43989,
  built by `build-fat.sh` at source stamp `93d644cc…`, plus the SDL#5 ppc SDL
  member. The engine was not rebuilt for the SDL swap (manager decision).
- Six slices: ppc750 ppc7400 ppc970 x86_64 i386 arm64. Installed engine md5
  `d32851f17fdebd0158f51815cee567f9`, bundle version `5.11-oldmac-v2.13.0`.
- The SDL ppc member in the DMG (`0965a00d…`) is the SDL#5 asset
  (`5f8cb597…`) plus the ad-hoc signature `make-dmg.sh` adds to every
  member. The code bytes are identical: 14 header bytes change and a
  signature is appended. v2.12.0's ppc member was signed the same way.

## Smoke from this exact image

| host | OS | GPU | slice | result |
|---|---|---|---|---|
| yosemite | 10.3.9 Panther | ATI Rage 128 | ppc750 | PASS, new game started (#35), `logs/yosemite-80-deploy-smoke.log` |
| mini-g4 | 10.4.11 Tiger | ATI Radeon 9200 | ppc7400 | PASS, new game started, `logs/mini-g4-thousands-deploy-smoke.log` |
| g5-tiger | 10.4.11 Tiger | ATI Radeon 9600 | ppc970 | PASS, native 1680x1050, new game started, `logs/smoke-g5-tiger.log` |
| imac-2019 | 15.7.9 Sequoia | AMD Radeon Pro 580X | x86_64 | PASS, Jenkins #8, console guard ready, demo1 118.8 fps vsync on, bloom 1 MSAA 4, `logs/smoke-imac-2019.log` |
| workstation | 26.6.2 | Apple M5 | arm64 | PASS, demo1 59.3 fps vsync on, bloom 1 MSAA 4, `logs/smoke-workstation.log` |

Installed but not smoked: mini-intel (GMA 950, Lion, headless, so its captures
are invalid). Not updated: mini-intel2 (held by buildhost all night), mini-sl
(off after the #84 kernel panic), imac-g5, sawtooth, quicksilver and the G5
Panther/Leopard partitions (off or not booted). i386 has still never been
tested on hardware.

## Fixes proven on hardware

- **#83 / SDL#5, PPC at Thousands of colors:** mini-g4 at 16 bpp. The old
  SDL failed with "Couldn't init SDL video: Unsupported display mode" in 3 s;
  v2.13.0 ran demo1 at 54.3 fps. Depth was restored to 32 bpp.
- **#80, bloom at viewsize 80:** G3 engine screenshots before and after on
  the same install (`frames/`). v2.12.0 shows the blue picture-in-picture and
  a blue cast; v2.13.0 is clean.
- **#79, capability probe:** `benchmarks/experiments/2026-09-22-q2-79-capability-probe/`.
- **imac-2019, 4x MSAA:** production demo1 went from 73.5 to 118.8 fps with
  vsync on (bench, vsync off: 73-75 to 145-154).
  `benchmarks/experiments/2026-09-22-imac2019-msaa/`.
