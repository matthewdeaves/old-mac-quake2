# Mistakes: renderer features

## Entry lookup

- 2026-09-22 Offscreen bloom workspace: too little benefit on GeForce 9400 → `MISTAKES.md`
- 2026-09-22 Raising GeForce 9400 MSAA with bloom spends too much headroom → `MISTAKES.md`
- 2026-09-22 Indexed-model range hints did not improve the Radeon 9200 → `MISTAKES.md`
- 2026-09-22 G4 bloom still breaks the playable floor after framebuffer optimizations → `MISTAKES.md`
- 2026-09-22 G4 stencil-operation and submission experiments did not win → `MISTAKES.md`
- 2026-09-13 Forcing 16-bit `gl_texturesolidmode`/`gl_texturealphamode` helped the G3, cost the G4 (#69) → `MISTAKES.md`
- 2026-05-31 `gl_caustics` drew a grid of circles on water (fixed v2.2.6) → `docs/archive/MISTAKES.md`
- 2026-05-31 `gl_trans_lighting` port missed a guard and `ERR_DROP`ed on base1 glass, presenting as a freeze (v2.2.5) → `docs/archive/MISTAKES.md`
- 2026-05-29 (updated 2026-08-23, #33) Fixed-function bloom: too slow on PPC, and `R_LoadPic` eats the screen texture → `MISTAKES.md`
- 2026-05-29 Procedural/effect textures get freed on map change unless protected (latent) → `docs/archive/MISTAKES.md`
- 2026-05-23 `gl_stencilshadow 1` on Tiger ATI drivers regressed 60% fps → `docs/archive/MISTAKES.md`
- 2026-06-06 The blob-shadow fallback the configs claimed was never implemented, and the first attempt drew nothing → `docs/archive/MISTAKES.md`
- 2026-05-23 Multitexture state leaks into ad-hoc draw passes on GMA 950 → `docs/archive/MISTAKES.md`
- 2026-05-21 `R_ApplyGLBuffer` toggling multitexture destroyed the `GL_COMBINE_EXT` setup → `docs/archive/MISTAKES.md`
