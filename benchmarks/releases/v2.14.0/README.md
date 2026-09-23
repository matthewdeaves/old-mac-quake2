# v2.14.0 release evidence

- `dist/Quake2-OldMac-v2.14.0.dmg`, SHA256
  `9655e37ebe740e3759c708d0a33ba2c9068197a59f8c6375a09f09543dc7d26a`,
  packaged on mini-g4 (Tiger G4). Tag `v2.14.0` on 77856bab. Fat build stamp
  `2dda48e8…`. Installed engine md5 `586c75973f4fca42e7a8fed42bd4d19f`.
- Every product carries ppc750 ppc7400 ppc970 x86_64 i386 arm64. The inner
  Mach-O headers of the PowerPC members were checked against the fat entries
  inside the DMG.

## Build integrity (lock incident)

buildhost's `tests/test-bench-lock.sh` deleted this build's mini-intel claim at
about 10:10-10:15 (old-mac-build-host, confirmed by buildhost). Checked before
shipping:
- Every write under `~/oldmac/quake2` on mini-intel in 10:05-10:25 falls within
  this build's own timeline (10:10:16 to 10:17:42). The shared SDK, SDL and
  vendor directories had 0 writes. alephone ran a PowerPC configure and build
  in its own `~/oldmac/alephone` tree at the same time; the known hazard is two
  PPC builds in one object tree, which this was not.
- The CPU-subtype stamps are verified (above), and every PowerPC slice was
  smoked on hardware (below).

## Smoke from this exact image

| host | OS | GPU | slice | result |
|---|---|---|---|---|
| yosemite | 10.3.9 | Rage 128 | ppc750 | PASS, new game started, 0 images left attached |
| mini-g4 | 10.4.11 | Radeon 9200 | ppc7400 | PASS, new game started |
| g5-tiger | 10.4.11 | Radeon 9600 | ppc970 | PASS, new game started |
| mini-intel2 | 10.7.5 | GMA 950 | x86_64 | PASS, demo1 43.2 fps |
| imac-2019 | 15.7.9 | Radeon Pro 580X | x86_64 | PASS, Jenkins #9, console guard ready, 118.4 fps vsync on, `Scene resolve: 2560x1440, requested 8, color/depth samples 8/8` |
| workstation | 26.6.2 | Apple M5 | arm64 | PASS, 55.0 fps vsync on; local control lines kept |

Installed but not launched: mini-sl (#84, files only). mini-intel is headless:
installed, and its smoke is NOT TESTED (no fullscreen mode). Off: sawtooth,
quicksilver, imac-g5, the quad G5.
