# Feature inventory

Inventory of renderer and engine changes shipped by this fork.
`docs/CONFIG.md` holds current cvar defaults; ADR 0010 records measured default selection.
The table names implementation commits; release state is in `docs/STATUS.md`.

Each row is a shipped renderer or engine feature with the commit that landed it. Cvars and their per-machine defaults are in `docs/CONFIG.md` (one place for defaults); measured costs that drove a default are in ADR 0010. Release-by-release history: `docs/STATUS.md` and `docs/archive/RELEASE-HISTORY.md`.

## Inventory

| Feature | Cvar(s) | Per-machine defaults | Commit |
|---|---|---|---|
| `GL_FOG` (linear/exp/exp2, colour, range) | `gl_fog*` | yosemite off, others on | `c3d1de3` |
| Underwater frustum sine-warp | `gl_waterwarp` | all = 1 | `2c39855` |
| Dynamic lightmap subrect upload (dirty `xmin/xmax` tracked in `LM_AllocBlock`, uploaded with `GL_UNPACK_ROW_LENGTH`) | `gl_lightmap_subrect` | all = 1 | `937a870` |
| Sawtooth dlight policy: billboard halos instead of relight | `gl_dynamic 0` + `gl_flashblend 1` | sawtooth | `7051a09` |
| 2x anisotropic on the bottom of the fleet (chip max for GF2 MX / R128; silently no-ops without the extension) | `gl_anisotropic 2` | sawtooth + yosemite | `d82d3fa` |
| Q3-style overbright lightmaps (`GL_RGB_SCALE_EXT 4`) | `gl_overbrightbits 4` | the four multitex + combine boxes | `044b6f7` |
| stb_image JPEG loader, drops the libjpeg dep and enables `WITH_RETEXTURING` on every slice | `gl_retexturing` | on above 32 MB VRAM; off yosemite + sawtooth | `3b594e1` |
| Group-draw vertex-array dispatch; compile-time default per slice via an `__ALTIVEC__` probe | `gl_groupdraw` | 1 on G4+ and x86, 0 on yosemite | `594eeba` + `78c26f2` (the TexEnv fix) |
| HD texture pack search path inside the bundle | none (`Q2_GetBundleHDPakPath`) | always on if `Contents/Resources/hd-pak/` exists | `b9588bc` |
| Yosemite ULTIMATE: full-detail textures + trilinear + alias shadows + fog | `gl_picmip 0` `gl_round_down 0` `gl_texturemode GL_LINEAR_MIPMAP_LINEAR` `gl_shadows 1` `gl_fog 1` | yosemite only | `e8ae174` |
| Static-analysis pass + 7 warning fixes (`colortable[768]`→`[256]`, `temp[128*128]`→`[34*34]`, `lerp[3]=0` init, malloc-NULL guards, sign cast, `Wpointer-arith` floor) |, | all builds | `9440302` |
| `gl_minlight` + `gl_skydistance` | both | yosemite 16, sawtooth 8, others 0 | `2c1fd88` |
| `R_AddDynamicLights` row cull (skip rows where `td >= fminlight`) |, | all dlight-running machines; no-op at `gl_dynamic 0` | `da905a2` |
| `gl_particle_square` + `r_2D_unfiltered` | both | square on yosemite; unfiltered on all six | `0b4b184` + `2cdcc3b` |
| AltiVec `R_LerpVerts` (alias frame lerp) + 16-byte-aligned `s_lerped` |, | G4 slice only via `__ALTIVEC__`; fps-neutral, establishes the working AltiVec template | `712a244` |
| World decals: BSP fragment clipping (KMQuake2 `r_fragment.c` port) + alpha-blended patches, FIFO with fade-out. Texcoord origin from the **actual impact point**, not the fragment centroid, so the texture centres on the hole regardless of clip geometry. `GL_CLAMP_TO_EDGE` so alpha-0 edges do not bleed. Per-impact radii: bullet 6, blood/greenblood 8, blaster 10, grenade 24, rocket 28, big 36. Hooks: `TE_GUNSHOT`/`SHOTGUN`/`BULLET_SPARKS`, `TE_BLOOD`, `TE_GREENBLOOD`, `TE_BLASTER`/`BLUEHYPERBLASTER`, `TE_*_EXPLOSION` | `gl_decals` `gl_decal_max/life/fade` | see CONFIG.md | `5c78ca6` + `ffc599d` + `e891163` |
| Latent 5.11 `R_FindImage` NULL-deref fix: the `.tga` and `.jpg` branches called `R_LoadPic(NULL, …)` on missing files, segfaulting in `R_ResampleTexture` |, | all builds | `5c78ca6` |
| MSAA wired through the SDL backend (`SDL_GL_MULTISAMPLE` + `qglEnable(GL_MULTISAMPLE)` at GL init), `CVAR_LATCH` so `vid_restart` picks it up | `gl_msaa_samples` | see CONFIG.md | `5c54a6e` |
| Per-weapon blast marks: `CL_TraceExplosionSurface` fires six cardinal-axis `CM_BoxTrace` calls from the blast origin and projects the decal onto the nearest solid hit. Rocket `DECAL_BURN` r40 (48 for `_BIG`), grenade `DECAL_SCORCH` r22, plasma `DECAL_PLASMA` r16, BFG `DECAL_BFG` r40, rail `DECAL_RAIL` r7 from the beam direction. Root cause: explosion temp-entity packets carry **no surface normal**, so `cl_tempentities.c:862,926` faked `{0,0,1}` and a wall shot found nothing | `gl_decals` | all decal machines | v2.5.0 |
| Blob shadow for the non-stencil path: one textured `GL_QUADS` on the floor plane instead of the per-triangle projection, radius from the alias frame bbox | `gl_shadows` | machines at `gl_stencilshadow 0` | v2.5.0 |
| `vid_desktopfullscreen` + `GLimp_ForceDesktopFullscreen()` | `vid_desktopfullscreen` | iMac-class | v2.2.0, ADR 0008 |
| watchlink UDP player-state feed | `watch_*` | off by default | v2.5.0, `docs/WATCHLINK.md` |
