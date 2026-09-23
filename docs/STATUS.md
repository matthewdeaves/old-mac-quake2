# Release history

One line per release, with the figures measured for it. Mechanisms live in
`docs/adr/`, negatives in `MISTAKES.md`, every benchmark row in
`benchmarks/results.csv`.

**v1.0.0** (2026-05-19), Phase A. Vanilla yquake2 5.11 as a fat universal
`Quake2.app` on all six bench machines, per-machine autoexec via CFBundle, TGA
screenshot writer fixed for top-down orientation. Baseline grid in ADR 0010.

**v2.0.0** (2026-05-21/24), GL1 and KMQuake2 cherry-picks: `gl_fog`,
`gl_waterwarp`, `gl_lightmap_subrect`, `jpeg.c` on stb_image (drops libjpeg,
unlocks `WITH_RETEXTURING` everywhere), `gl_groupdraw` + `r_buffer.c`, bundle
HD-pak search path, world decals, MSAA, `gl_minlight`, `gl_skydistance`,
`gl_particle_square`, `r_2D_unfiltered`, AltiVec `R_LerpVerts`, dlight row cull,
static-analysis fixes. The round's key fix was `78c26f2` (MISTAKES.md). Yosemite
ULTIMATE shipped at 25.10 / 45.15 fps.

**v2.1.0** (2026-05-29), `gl_glows`, `gl_trans_lighting`, `gl_caustics` on the
multitex boxes; `gl_zfix` everywhere; `gl_farsee` on x86; CVA on the group-draw
path (fps-neutral, kept for parity). `gl_bloom` wired but disabled. Effect
textures protected in `R_FreeUnusedImages`. `make-dmg.sh` added.

**v2.2.0** (2026-05-31), iMac G5 added as a fourth PowerPC slice (`ppc970`,
10.5 SDK, `-DQ2_ARCH_PPC970`); per-arch baseline config layer added so unknown
Macs stop getting stock defaults; `vid_desktopfullscreen` and
`GLimp_ForceDesktopFullscreen()` (ADR 0008); fleet-wide fullscreen-by-default.
Regression check: mini-g4 57.2, mini-intel 97.9, yosemite 31.9 fps.
**Shipped broken**, see v2.2.1.

**v2.2.1**, hotfix: the `Cbuf_AddText` config overflow that wedged the R300 on
"start new game" (ADR 0007). Validated a real new game on all six GPU classes.

**v2.2.2**, documented, never tagged; the first-launch `vid_restart` was
reverted (MISTAKES.md) and the G3 start-a-game crash was still live.

**v2.2.3**, the G3 start-a-game crash fixed by moving the config call site
before `CL_Init` (ADR 0007). WASD + mouse-look default scheme. Fleet: yosemite
25, quicksilver 64.0, mini-g4 56.8, mini-intel 94.8 fps; imac-g5 native
1440x900 30 fps with 2x MSAA.

**v2.2.4**, DMG packaging integrity: end-to-end content verification, the DMG
host moved off the G3 to Tiger, `deploy-dmg.sh` and `smoke-dmg.sh` added
(ADR 0005, ADR 0006). Validated from the mounted image on G3 (20.6 fps), G4-mini
(38.5), G5 (30.0, no R300 hang).

**v2.2.5**, `gl_trans_lighting` `ERR_DROP` on base1 fixed, one line in
`r_light.c` (MISTAKES.md).

**v2.2.6**, `gl_caustics` rewritten as a sum of gratings rather than a product
(MISTAKES.md); `deploy-dmg.sh` gained per-binary md5 verification with exit 7.

**v2.3.x – v2.4.x**, see `git log`.

**v2.5.0** (2026-06-06), per-weapon blast marks on walls via
`CL_TraceExplosionSurface`, four new procedural TGAs, real blob shadow for the
non-stencil path, stencil shadows enabled across the G4 fleet, `deploy.sh`
player-model fix, watchlink Bonjour `.local` resolution on 10.3/10.4. **The G4
stencil figures behind this release came from the `res=1` runs and are invalid;
issue #7.** imac-g5 46.8 fps demo1+demo2 at 1440x900.

**v2.5.1**, sawtooth (GeForce2 MX) added to the stencil set on an A/B of
74 → 60 fps demo1 (~19%), 68 fps demo2. Same `res=1` caveat applies. Config-only
round. (sawtooth's PRAM battery is dead, clock reads 1970; harmless to the game.)

**v2.6.0** (2026-07-25), cross-configuration round. `ppc7400` moved to the
10.3.9 SDK at min-10.3 and `x86_64` to min-10.6 (ADR 0001); the `-faltivec`
cpusubtype near-miss caught and the assert-and-re-stamp added; G3-on-Tiger
verified at 21.0 fps with slice selection proven by positive control; nine
`res=1` bench rows identified and `bench.sh` hardened; iMac G5 and iMac G4 model
IDs mapped (ADR 0007); `yosemite-tiger` wired in as a bench target with a guard
against running it alongside `yosemite`; the bundle now carries the port
version. arm64 was initially closed as out of scope; that decision was later
superseded by the native arm64 slice described in ADR 0015.

**Post-v2.6.0** (2026-08-19/20), Linux dedicated server release, measured query
amplification, and a remote buffer overflow in `Cmd_TokenizeString` found by
fuzzing and fixed (ADR 0011). Documentation consolidated into `docs/adr/`.

**v2.8.1** (2026-08-27), Universal 6-slice release:
- Six-slice fat binary: `ppc750`, `ppc7400`, `ppc970`, `x86_64`, `i386`, `arm64`.
- Modern macOS AppKit compatibility: enabled regular activation policy and layer-backed window surface observation for macOS 10.14+ (Mojave through macOS 15 Sequoia) without breaking 10.3/10.4 PPC builds (issue #26).
- Bloom renderer overhaul with dedicated render targets (`qglTexImage2D`) replacing `R_LoadPic/it_pic` (issue #33). The Apple Silicon black-screen fault was fixed by routing GL readback through sdl12-compat after context creation; arm64 now enables the measured bloom profile by default.
- GPU-family capability tier for unmapped machines with automatic feature scaling (issue #32).
- Resolved stencil shadow configuration across G4 and sawtooth profiles (issues #7, #25, #34).
- Linux dedicated server 8.70 with rate-limiting and security hardening for x86_64 and aarch64.

**v2.9.0 – v2.11.2**: see the GitHub tags and `benchmarks/releases/`.

**v2.12.0** (2026-09-22), M5 stutter fix; G4 combined depth/stencil clear
(40.6 → 55.7 fps); GeForce 9400 bloom partial restore (42.7 → 50.0); G3
projected shadows (demo2 28.4).

**v2.13.0** (2026-09-23), PowerPC launch at Thousands of colors (SDL#5, #83);
imac-2019 4x MSAA (73.5 → 118.8 fps vsync on); bloom border at reduced
viewsize (#80); GPU check on mapped Macs (#79).

**v2.14.0**, imac-2019 8x MSAA through `gl_scene_resolve` (176 fps vs 74,
2560x1440), which now fails open; a renderer that can't start exits with an
error instead of crashing; GMA 950 profile says MSAA 0 (no hardware MSAA).

## Open

- #69: per-class measurement for sawtooth, quicksilver and imac-g5 (off).
- #25: sawtooth's four features (off).
- imac-2019: vsync caps at about 119 fps on a 60 Hz panel in desktop
  fullscreen; cause open (#69).
- GL1 gamma correction: 5.11 has none on the GL path; SDL_SetGamma works.
