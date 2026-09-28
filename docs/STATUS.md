# Status

Current release state: the latest releases with the figures measured for them, and the open items. Latest is v2.15.1 (2026-09-27).
Releases before v2.12.0 (v1.0.0 to v2.11.2) are in `docs/archive/RELEASE-HISTORY.md`. Mechanisms live in `docs/adr/`, negatives in `MISTAKES.md`, fixes in `BUGFIXES.md`, every benchmark row in `benchmarks/results.csv`, tags in `benchmarks/releases/`.

## v2.15.1 (2026-09-27)

Fix: `R_ApplyCapabilityTier()` never reset `gl_dynamic`/`gl_flashblend` on a capability-tier GPU mismatch, so a sawtooth-shaped real-hardware workaround (`gl_dynamic 0`, `gl_flashblend 1`) leaked onto qemu-tiger3d, which reports sawtooth's `hw.model` while emulating a different GPU (#99). No effect on real fielded hardware, which never hits the mismatch branch.

## v2.15.0 (2026-09-23)

G5 tower glows, lit glass, caustics, 16x aniso and retexturing (50.6 to 50.15 fps; stencil stays off at -10%, #86); a CGL GPU tier gives unmapped Radeon 9500-X850 G5s the tower profile without bloom (148.7 fps, #87); per-class baseline, no class under its floor (#69).

## v2.14.0

imac-2019 8x MSAA through `gl_scene_resolve` (176 fps vs 74, 2560x1440), which now fails open; a renderer that can't start exits with an error instead of crashing; GMA 950 profile says MSAA 0 (no hardware MSAA).

## v2.13.0 (2026-09-23)

PowerPC launch at Thousands of colors (SDL#5, #83); imac-2019 4x MSAA (73.5 to 118.8 fps vsync on); bloom border at reduced viewsize (#80); GPU check on mapped Macs (#79).

## v2.12.0 (2026-09-22)

M5 stutter fix; G4 combined depth/stencil clear (40.6 to 55.7 fps); GeForce 9400 bloom partial restore (42.7 to 50.0); G3 projected shadows (demo2 28.4).

## Open

- #69: per-class measurement for sawtooth (off); quicksilver and imac-g5 done.
- #25: sawtooth's four features (off).
- #100: qemu-tiger3d shows magenta/purple corruption under real `gl_dynamic 1` relighting: confirmed R300-emulation gap, not an engine bug, tracked as qemu#15 on qemumac's side.
- imac-2019: vsync caps at about 119 fps on a 60 Hz panel in desktop fullscreen; cause open (#69).
- GL1 gamma correction: 5.11 has none on the GL path; SDL_SetGamma works.
