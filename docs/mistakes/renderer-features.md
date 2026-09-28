# Mistakes: renderer features

Renderer experiments and bugs: framebuffer, bloom, MSAA, stencil shadows, decals, caustics, glass lighting, texture formats, multitexture state. Themes: bench every GPU class separately (a G3 win is no evidence for a G4); same bug on different drivers means a logic bug, not driver state; GL fixed-function state is a global, so the caller owns cleanup; when porting a feature port the whole diff including relaxed guards; bloom is a full-resolution capture and stays off on weak GPUs. Newest first.

## 2026-09-22 Offscreen bloom workspace: too little benefit on GeForce 9400
Native 1920x1080, requested MSAA2, bloom256/darken4: single-sample renderbuffer copies demo2 A/B/B/A 48.30/48.85/48.65/48.20 fps; direct texture ping-pong 47.40/50.15/49.30/48.75 (demo2), then 50.25/50.65/50.90/49.95 (demo1). Small benefit, only 0.675 fps between demo1's averaged warm legs.
Reverted the FBO code rather than ship extra legacy-driver paths for it; does not rule out a different approach to the full-resolution capture/composite. Evidence and recoverable patches: `framebuffer/intel-fbo`.

## 2026-09-22 Raising GeForce 9400 MSAA with bloom spends too much headroom
Native 1920x1080, optimized bloom on, demo2 MSAA2 vs MSAA4: warm 48.25 vs 30.40 fps (three runs each). Selected frames show only modest edge changes; keep 2x. Cvar requests verified; this runtime did not log the driver's actual sample count. Evidence: `benchmarks/experiments/2026-09-22-framebuffer/intel-aa/`.

## 2026-09-22 Indexed-model range hints did not improve the Radeon 9200
Optional `glDrawRangeElements` with known model/shadow vertex bounds instead of `glDrawElements`. 1024x768, combined clears, MSAA2, projected shadows: demo1 A/B/B/A warm 55.65 / 55.70 / 55.70 / 55.70 fps; ten captured frame pairs pixel-identical. Reverted; no new setting earns a default. Evidence and rejected patch: `benchmarks/experiments/2026-09-22-framebuffer/g4-drawrange/`.

## 2026-09-22 G4 bloom still breaks the playable floor after framebuffer optimizations
Radeon 9200 mini-G4, 1024x768, MSAA2 and stencil shadows kept: combined clears lift bloom-off demo1 from 40.60 to 55.70 fps. Bloom with partial restoration and darken=4 costs 18.15 fps at bloom-size 128 and 15.10 at 256 (warm means, three runs each). Keep bloom off; smaller blur work and the new clear path do not make the full-screen capture/composite affordable. Does not negate the GeForce 9400 partial-restoration win.

## 2026-09-22 G4 stencil-operation and submission experiments did not win
Shadow coverage `GL_INCR` to `GL_ZERO`: same pixels, unchanged 40.60 fps (A/B/B/A). Reverted. Compiled-array locking 34.80 vs 40.60 fps; retained-world VBO submission 40.65 vs 40.60 (noise). No new default. Combining depth/stencil clears was the win in this driver, not shadow geometry or the stencil op.

## 2026-09-13 Forcing 16-bit `gl_texturesolidmode`/`gl_texturealphamode` helped the G3, cost the G4 (#69)
#68 found `GL_EXT_paletted_texture` and `GL_EXT_shared_texture_palette` absent on both the G3's Rage 128 and the G4's Radeon 9200, so `gl_ext_palettedtexture 1` is a no-op on both and both fall to `"default"`. On the G3 forcing `GL_RGB5`/`GL_RGBA4` was a clean +13.3% (25.85 to 29.30 fps, bit-identical x3). Same override on mini-g4: **-12.2% (40.25 to 35.35 fps)**, noisy (35.5/36.3/34.4).
Why: the Rage 128's `"default"` happened to be worse than an explicit 16-bit request; the RV280's is apparently already efficient and forcing a format adds a conversion step. Same absent-extension reasoning, opposite driver behaviour: bench every class separately. Reverted (EXTRA-only, nothing in mini-g4's shipped cfg). Evidence: `benchmarks/results.csv` (`3f6cf8b9`/mini-g4 rows), #69.

## 2026-05-31 `gl_caustics` drew a grid of circles on water (fixed v2.2.6)
Brightness was a PRODUCT of gratings, not a SUM. The overlay tiled soft round blobs across every water surface on both the G5 (Radeon 9600/Leopard) and G3 (Rage 128/Panther).
The first theory was a TMU state leak from `gl_trans_lighting`; the identical artifact on two different GPUs means a deterministic logic bug in shared code (water is `SURF_DRAWTURB` and skips the lightmap path anyway). *Same bug on different drivers means look for logic, not driver state.*
Root cause: `R_InitCausticTexture` (`r_misc.c`) computed `a*b` of two sine gratings, then cubed it: a product peaks at a lattice of isolated points, so cubing made round blobs. Real caustics are connected veins, the zero-crossing contour of a **sum** of waves.
Fix: brightness = `1 - |sum_of_sines| / N`, sharpened with tunable `pow()` and gain (`caustic_waves[]`/`CAUSTIC_POWER`/`CAUSTIC_GAIN`, soft "K" preset shipped); integer frequencies keep the tile seamless. `r_decal.c` was not involved.
Tooling: snap-Firefox is sandboxed and cannot read `/tmp` or anything outside `$HOME`; use Chrome and stage previews under `$HOME`.

## 2026-05-31 `gl_trans_lighting` port missed a guard and `ERR_DROP`ed on base1 glass, presenting as a freeze (v2.2.5)
A byte-verified DMG still froze "start a new game" on the G4-mini and iMac G5 (state `R`/`U`, pegged CPU, ignored SIGTERM), G3 fine. Looked like a fullscreen/R300 wedge; with `logfile 2` flushed the log read `ERROR: R_BuildLightMap called for non-lit surface` (`r_light.c`, `ERR_DROP`).
Root cause: at map load `r_model.c` calls `LM_CreateSurfaceLightmap` for `SURF_TRANS33/66` surfaces when the cvar is on, which calls `R_BuildLightMap`, whose stock guard rejects `SURF_SKY|SURF_TRANS33|SURF_TRANS66|SURF_WARP`. kmquake2 relaxes that line to `(SURF_SKY|SURF_WARP)`; we copied the feature but not the guard. Fix: that one line in `r_light.c`.
Lessons: (1) a "fullscreen crash" with a live pegged process and no crash log is almost always an `ERR_DROP`: read the flushed log first (ADR 0009). (2) The G3-ok/G4+G5-fail split was a red herring: it tracked which features the per-machine config enables, not the CPU; bisect by the actual variable. (3) `+map base2` is not "new game": test the real first map (ADR 0009). (4) When porting a feature, port the whole diff, including the defensive guards it relaxes.

## 2026-05-29 (updated 2026-08-23, #33) Fixed-function bloom: too slow on PPC, and `R_LoadPic` eats the screen texture
`r_bloom.c`/`gl_bloom`: capture the back buffer with `glCopyTexSubImage2D`, downsample, darken, separable blur, additive composite at the end of `R_RenderView`.
1. **Prohibitively slow on a 2001 GPU:** quicksilver R9000 Pro 66.95 to 25.50 fps demo1 1024 (-62%), below the ~40 fps G4 tolerance; the per-frame fullscreen copy plus sample passes are fillrate murder on a 1999-2005 part.
2. **Visually broken on GMA 950/Lion:** first cut left a black box in the corner plus a heavy additive wash; a "restore the scene from the captured texture" blit brought the 3D scene back black, because `R_LoadPic(..., it_pic, ...)` resizes and repacks a large (1024^2) pic texture so the capture region overflows the real texture and the copy silently stays empty.
Shipped **disabled** (`gl_bloom 0` everywhere), code kept in-tree. Lessons: (a) a fullscreen post-process is the wrong shape for the PPC fillrate budget; (b) never use `R_LoadPic`/`it_pic` as a render target.
**2026-08-23 (#33): (b) fixed, (a) stands.** The 256x256 cap was `R_Upload32` (`r_image.c`), which clamps ANY upload, silently shrinking the screen-res capture texture while `r_bloom.c` used uncapped dimensions for `glCopyTexSubImage2D`. Redone as two fixed manual texnums (`TEXNUM_BLOOMSCREEN`/`TEXNUM_BLOOMEFFECT`, `header/local.h`) created via `qglTexImage2D`, bypassing `R_LoadPic`; this engine never calls `glGenTextures`, so a redo must stay in the manual-id space.
Verified visually (screenshot.sh, gl_bloom forced on, mini-intel): correct scene with visible bloom. Cost confirmed: GMA 950/Lion 94.0 to 53.85 fps (**-43%**, exploratory bench, not in results.csv, see `bench.sh`'s `BENCH_CSV`). Inherent to a full-resolution `glCopyTexSubImage2D` in GL1 with no FBO; the capture cannot be made sub-resolution. Still disabled everywhere; G5/imac-2019/Apple Silicon headroom was untested then (see BUGFIXES #33).

## 2026-05-29 Procedural/effect textures get freed on map change unless protected (latent)
`gl_glows` and `gl_caustics` build a procedural texture once at `R_Init` and stash the `image_t*` in a global. `R_FreeUnusedImages` runs every map change and frees any image whose `registration_sequence` is not current; these were not in the protect list, so the first map change would free them and the feature paths would bind a deleted texnum. It did not surface in demo1 benches or screenshots because those frames barely exercise the shell and caustic paths: a "looked fine, was broken" trap.
**Any texture created once at init and held in a global must be added to the `R_FreeUnusedImages` protect block** (ADR 0012).

## 2026-05-23 `gl_stencilshadow 1` on Tiger ATI drivers regressed 60% fps
mini-g4 (R9200, ATI Tiger), demo2 1024x768: **103.6 to 40.6 fps**. The R9200's per-fragment `GL_INCR` stencil op runs on a very slow driver path and the bench scene has many monsters. Reverted on all four slow-stencil machines; blob shadows (`gl_shadows 1`) stayed on.
Lesson: 8-bit stencil being *requested* does not mean the per-fragment op is fast; `have_stencil` in `r_mesh.c` only checks that stencil bits were granted, so it cannot guard for this.
**Reversed 2026-06-06 on figures now known invalid**: they came from `res=1` runs that rendered 1x1 pixels (ADR 0009). Re-taking it is issue #7, see ADR 0010; do not quote the 2026-06-06 numbers.

## 2026-06-06 The blob-shadow fallback the configs claimed was never implemented, and the first attempt drew nothing
`R_DrawAliasShadow` (`r_mesh.c:427`) projects **every** model triangle flat onto the floor; the stencil ops (`GL_EQUAL,1,2` + `GL_INCR`) alone mask each floor pixel to draw once. With `gl_stencilshadow 0` the overlapping projected triangles each re-blend at alpha 0.5 into dark blotches.
The first blob replacement used `GL_MODULATE` with a `(0,0,0,0.5)` vertex colour, which **collapses to transparent black on the Tiger ATI driver**: no shadow at all. Fixed with `GL_REPLACE` and the 50% alpha pre-baked into `shadow.tga`.

## 2026-05-23 Multitexture state leaks into ad-hoc draw passes on GMA 950
`R_DrawDecals` (`r_decal.c`) bound the decal texture to TMU0, called `R_TexEnv(GL_MODULATE)` and drew alpha-blended quads. Correct on yosemite (Rage 128, no multitex) and mini-g4 (R9200); on mini-intel (GMA 950, Lion) minigun decals were **light grey discs** instead of dark bullet holes (shape, position, falloff right, colour wrong).
Root cause: `R_DrawWorld` leaves multitexture **enabled** with TMU1 holding the lightmap and an overbright combiner state (`GL_RGB_SCALE_EXT 4` at `gl_overbrightbits 4`). The R9200 and Rage 128 drivers apparently reset TMU1's combine state when TMU0 binds a new texture; the GMA 950 Lion driver does not, so the bright lightmap modulated the dark decal up to grey.
Fix: explicit `R_EnableMultitexture(false)` at the start of `R_DrawDecals`. Lesson: GL state cleanup is the caller's job; any ad-hoc pass after `R_DrawWorld` must disable multitexture if it expects single-texture semantics. "It works on PPC" is not a sanity check for a state-machine bug.

## 2026-05-21 `R_ApplyGLBuffer` toggling multitexture destroyed the `GL_COMBINE_EXT` setup
The port of yquake2-latest's `gl1_buffer.c` called `R_EnableMultitexture(true)` on flush entry and `(false)` on exit. Walls, floors and ceilings rendered flat yellow/beige (`gl_overbrightbits 4`) or flat grey-cyan (OBB 2) on **every** multitex platform. Diagnosis first pointed at retexturing, a driver quirk, or missing HD textures; `gl_groupdraw 0` fixing the visuals narrowed it to the flush path.
Root cause: `R_DrawWorld` sets TMU1's TexEnv to `GL_COMBINE_EXT` with `RGB_SCALE_EXT = gl_overbrightbits` **before** `R_RecursiveWorldNode`; each flush's `R_EnableMultitexture(true)` calls `R_TexEnv(GL_REPLACE)` on TMU1, destroying it, so output was lightmap x 1.0 instead of (colormap x lightmap) x 4.
Fix (`78c26f2`): the buffer trusts the outer code to own the multitexture lifecycle; toggles removed, load-bearing comment at `r_buffer.c:113-123` and `:186-192`; `R_DrawWorld` and `R_DrawInlineBModel` enable mtex once for the whole BSP walk and disable after.
Generalises to every cherry-pick: fixed-function TexEnv is a global the buffer cannot touch. Upstream's `gl1_buffer.c` came from a tree that had hoisted the TMU1 setup out of `R_DrawWorld`; in our 5.11 base it stays there. **Any future port from yquake2-latest must check whether inner state configuration was hoisted into the new code or stayed in `R_DrawWorld`.**
