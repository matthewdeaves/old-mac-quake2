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
version. arm64 closed as out of scope, **that closure's stated reason has since
been withdrawn, see ADR 0003**.

**Post-v2.6.0** (2026-08-19/20), Linux dedicated server release, measured query
amplification, and a remote buffer overflow in `Cmd_TokenizeString` found by
fuzzing and fixed (ADR 0011). Documentation consolidated into `docs/adr/`.

## Open

- **Issue #7**, resolved for mini-g4: real-resolution stencil cost is 29%
  (41.1 vs 57.6 fps demo1 1024x768), machine is fill-bound, and the floor is
  settled as the raw bench number (`old-mac-build-host#22`) — 41.1 clears the
  ~40 fps floor, kept ON, no config change needed. sawtooth and quicksilver
  are still on the invalid `res=1` figures; re-bench when either is next
  powered up (both off as of 2026-08-23).
- Bloom redo with a dedicated render target and a sub-resolution budget
  (MISTAKES.md has the constraints).
- GL1 gamma correction, 5.11 has none on the GL path.
- Re-bench mini-g4 cold (ADR 0009, thermal).
- Both fleet framerate rows marked stale in `README.md`: sawtooth and imac-2019
  have not been benched since the stencil rollout.
