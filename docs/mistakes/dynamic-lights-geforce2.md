# Mistakes: dynamic lights on the GeForce2 MX

Three attempts to make `gl_dynamic 1` affordable on sawtooth (GeForce2 MX) all failed, plus one subrect port aimed at the wrong machine. Shipped answer: `gl_dynamic 0` + `gl_flashblend 1` (about 69 fps demo1 1024, billboard halos, no per-surface relight). The cost is CPU-side `R_BuildLightMap` + `R_AddDynamicLights` per dlight-touched surface, not GPU or AGP; AltiVec on stride-3 layouts is structurally limited. Newest first.

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
