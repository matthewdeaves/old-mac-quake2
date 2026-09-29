# Mistakes archive

Original entries moved from active history; wording is retained verbatim.
Search by ticket or heading, then read that entry.

## 2026-05-23 AltiVec `R_LerpVerts` produced warped alias-model geometry (commit `55bfeb8`, reverted)
Each vertex's `lerp = move + ov->v * backv + v->v * frontv` reduced to two `vec_madd`s plus one `vec_st`, gated by `#ifdef __ALTIVEC__` so only the G4 slice took it; `s_lerped` is `static vec4_t s_lerped[MAX_VERTS]`, naturally 16-byte aligned.
Monster alias models and the weapon viewmodel rendered with skewed, warped triangles on mini-g4; world BSP unaffected (`R_LerpVerts` runs only for alias models). **The user caught it visually. The bench reported +4.3% fps**, because the broken vertex maths was strictly cheaper than the correct maths.
Second smoking gun: a mini-g4 bench at 1024x768 of the **same** binary read **103.30 fps** the first time and **17.50 fps** on retry, likely the GL driver dropping to software fallback after the warped geometry corrupted its state.
Suspected root cause: `(vector float){a, b, c, d}` with `(float)byte` per-lane conversions. gcc-4.0 compiles it, but the lane-insertion codegen (3 byte loads + 3 sint-to-float + 3 vector inserts + literal 0) can go wrong if a stack temp is not 16-byte aligned or a `vec_ld` gets a wrong shift permute.
Lessons: (1) always corroborate a +N% AltiVec win with a screenshot diff against the scalar reference, especially in per-vertex or per-luxel pipelines; (2) `(vector float){a,b,c,d}` with non-constant lanes is risky on gcc-4.0 PPC, prefer `float v[4] __attribute__((aligned(16)))` then `vec_ld(0, v)`; (3) a retry needs that aligned-stack pattern **plus** a visual A/B from a fixed camera angle, scalar vs AltiVec build; (4) fps degrading rapidly across runs suggests bad geometry putting the driver in a degraded mode.

## 2026-07-25 `-faltivec` silently un-stamped the ppc7400 cpusubtype
Nearly shipped a fat no G3 could launch; caught before release. Root cause, blast radius and the assert-and-re-stamp fix: ADR 0001.
Lesson: a compiler flag added for one reason can quietly undo something unrelated three layers down; the only defence is asserting the property you care about on the artifact itself.

## 2026-05-31 Phantom "G3 corrupt renderer" was my own stale DMG mounts
Root cause and deploy-verify fix: ADR 0006. I assumed flaky retro hardware (old disk, non-ECC RAM); wrong: the G3 has a near-new SSD, hashed the file `060cc6dc…` three times deterministically in place, and a copy-to-disk hashed clean.
Do not reach for "flaky retro hardware" before hashing the file in place and copy-testing it. Verify at the LAST hop the user runs (the install directory); a failing deploy that prints a success-ish line is worse than one that errors.

## 2026-05-31 DMG packaging flipped ONE byte, illegal-instruction crash on every G4
Root cause, opcodes and three-part fix: ADR 0006. `hdiutil verify` is not a content check. Do not run build or packaging on the flakiest hardware in the fleet when a healthier machine does the same job.

## 2026-05-31 Config comments overflowed the command buffer and wedged the R300 on "new game" (v2.2.0)
Garbled config, R300 GPU wedged. Root cause and two-layer fix: ADR 0007.
Lessons: shipped config text has a hard size budget when the engine buffers it; a timedemo is not a substitute for actually starting a new game; when a change looks "harmless everywhere", check the machine with the least forgiving driver, which turns soft failures into hard ones.

## 2026-05-23 (try 3) AltiVec `R_BuildLightMap` is net-negative
Ported the `scale != 1.0F` paths (`nummaps==1` assign and `nummaps>1` accumulate). Output stride is 3 floats, incompatible with `vec_st`'s 16-byte aligned contract, so each loop builds aligned stack temps, `vec_madd`s, `vec_st`s to a temp, then scalar-extracts lanes 0-2.
- mini-g4 demo1 1024 on the `gl_dynamic 1` path that exercises it: **101.25 to 98.95 fps (-2.3%)**.
- sawtooth `gl_dynamic 1`: **14.70 fps**, slightly worse than try 2's 15.25.
Root cause: per-iteration setup overhead; the extra `vec_ld` per input, `vec_st` per output and three scalar loads exceed the scalar 3 fmul + 3 fmadd.
Reverted, including `__attribute__((aligned(16)))` on `s_blocklights`; sawtooth back to `gl_dynamic 0` + `gl_flashblend 1`.
*Do not re-attempt this function shape.* AltiVec on array-of-structures-3 layouts is structurally limited: `R_LerpVerts` can win because its output is `vec4_t` stride; where output stride is 3 (lightmaps, `vec3_t` arrays) setup dominates because the final store is scalar extracts. A win needs the **storage layout** to change (`s_blocklights` to `vec4_t` stride, one wasted lane), cascading into the store loop at `r_light.c:611-682` and `qglTexImage2D`'s `GL_RGBA` expectations.
Options left, none SIMD on the existing code: per-light subrect upload only; batching lights into one `R_BuildLightMap` pass; or accepting `gl_flashblend 1` permanently.

## 2026-05-19 (try 2) The lightmap subrect upload does not unlock it either
After `gl_lightmap_subrect` (commit `937a870`, predicted ~4-12% on AGP-bound dynamic uploads): **15.25 fps** demo1 1024x768 and **15.3 fps at 640x480**, identical at half the pixels. That is the smoking gun: the bottleneck is CPU-side `R_BuildLightMap` + `R_AddDynamicLights` per-luxel float maths, once per dlight-touched surface per frame regardless of resolution. **A bandwidth optimisation cannot fix CPU.** A regression that scales the same at two resolutions is CPU-bound.

## 2026-05-19 (try 1) `gl_dynamic 1` on sawtooth is catastrophic
**83 to 15 fps** demo1 1024x768, **95 to 15 fps** at 640 (about -80%). A rocket light or muzzle flash forces a `glTexSubImage2D` upload plus re-blend per affected surface, and demo1 has enough dlights to stay in that path most of the frame. The original autoexec comment ("GeForce2 MX still pays the lightmap-reblend cost; skip") was load-bearing. (Try 2 showed the cost is CPU, not AGP bandwidth as first assumed.)

## 2026-05-19 The subrect port was queued against the wrong machine
Before any code changed: the sister-project audit predicting +4.2% on demo1 1024 for yosemite overlooked that yosemite's autoexec sets `gl_dynamic 0`, which gates the entire dynamic path in 5.11 (`r_surf.c:279/429/651`); with dlights off `LM_UploadBlock(true)` never fires and there is nothing to optimise.
Per-machine autoexec settings change which code paths are hot: re-check a cherry-pick's justification against the target's own config first (ADR 0010).

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

## First-launch `vid_restart` for early per-machine defaults (v2.2.2, REVERTED)
Aim: apply tuned fullscreen, resolution and picmip on first launch instead of second. Worked on G4, G5 and Intel; **hard-crashed the G3**: `VID_CheckChanges → VID_LoadRefresh → QGL_Shutdown → Com_Error → VID_Shutdown → R_Shutdown → GLimp_Shutdown → SDL_GL_SwapBuffers`, `EXC_BAD_ACCESS at 0x134`. The same fatal reload, issued deliberately.
A compile guard `#if !(defined(__ppc__) && !defined(__VEC__) && !defined(Q2_ARCH_PPC970))` should have excluded the bare-G3 slice (`gcc-4.0 -arch ppc -mcpu=750` defines only `__ppc__`/`__POWERPC__`, not `__VEC__`), yet the crash persisted identically. Fix: drop `vid_restart`; the real fix moved the config call site (ADR 0007).
Lessons: (a) treat `vid_restart` as interactive-menu-only on legacy Panther/Rage 128; (b) "tested green on 4 of 5" is not "works", the oldest, least forgiving box is where video-init bites; (c) a fix that needs a per-slice compile guard to be safe is wrong for this fleet.
