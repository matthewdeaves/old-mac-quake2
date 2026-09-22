# Runtime config reference

The three-layer bundle config, its call-site constraint and the machine map are
in **ADR 0007**. This file is the cvar reference and the feature inventory.

Files: `scripts/bundle/autoexec-*.cfg`,
`yquake2/src/common/misc.c` (`Q2_ExecConfigFromBundle`).

## Custom cvars this fork adds on top of stock yquake2 5.11

| cvar | what | default per machine |
|---|---|---|
| `gl_fog` (+ `_mode` `_start` `_end` `_density` `_red/green/blue`) | cvar-driven `GL_FOG` | on (all); linear, far 2048-4096 |
| `gl_waterwarp` | underwater frustum sine-warp, magnitude 0..1 | 1 (all), one `sin()` per frame, only when `RDF_UNDERWATER` |
| `gl_decals` `gl_decal_max` `gl_decal_life` `gl_decal_fade` | KMQuake2 world decals | on; cap 8 (G3), 16 (sawtooth), 32 (qs/mg4), 64 (mini-intel), 128 (imac-2019) |
| `gl_msaa_samples` | MSAA, `CVAR_LATCH` (0/2/4/8/16) | 0 G3+sawtooth, 2 qs/mg4/mini-intel, 2 imac-g5, 8 imac-2019 |
| `gl_lightmap_subrect` | dirty-column-only dynamic lightmap upload | 1 (all); no-op when `gl_dynamic 0` |
| `gl_groupdraw` | batched `qglDrawElements` dispatch (+ `glLockArraysEXT` CVA) | 1 on G4+ and x86, 0 on G3 (no benefit, small cost) |
| `gl_minlight` | lightmap LUT clamp | 16 yosemite, 8 sawtooth, 0 elsewhere |
| `gl_skydistance` | sky box size | 2300 (vanilla) |
| `gl_particle_square` | force the `GL_POINTS` path | 1 on yosemite (R128 has no point parameters) |
| `gl_pointsprites` | `GL_ARB_point_sprite` particles | per-machine |
| `r_2D_unfiltered` | HUD pics on `GL_NEAREST` | 1 on all six (all use trilinear) |
| `gl_glows` | sphere-map energy shell glow | on multitex, off G3 + sawtooth |
| `gl_trans_lighting` | lightmapped glass/grates, latched at map load | on multitex, off G3 + sawtooth |
| `gl_caustics` | water-surface caustic overlay. **Water only**: skips lava and slime, see below | on multitex, off G3 + sawtooth |
| `gl_zfix` | polygon-offset coplanar surfaces | on (all) |
| `gl_clear_combined` | clear requested depth/stencil/colour buffers together | 1 on measured mini-G4 and G3 profiles and GeForce 9400 auto-default; 0 elsewhere |
| `gl_bloom_fastrestore` | restore only the overwritten bloom workspace corner, for any view size: the bloom capture spans the whole window, border included (#80) | 1 with the measured GeForce 9400 bloom auto-default; 0 elsewhere |
| `gl_farsee` | extended far clip, `CVAR_LATCH` | on ppc7400/ppc970/x86_64/arm64, off ppc750/i386 (#24) |
| `gl_bloom` (+ `_alpha` `_darken` `_size`) | fixed-function light bloom | on for tuned G5 dual, imac-2019 and arm64 profiles; off on G3/G4 and generic Intel. Apple Silicon measured 264.55 fps at 1920x1080 with bloom, 4x MSAA and desktop-fullscreen; evidence: `benchmarks/experiments/2026-09-12-bloom-readback/` |
| `vid_desktopfullscreen` | native-res same-mode fullscreen capture | on iMac-class (`ppc970` baseline + `imac-g5`); off elsewhere. **The only R300/Leopard-safe fullscreen, ADR 0008** |
| `watch_enable` `watch_host` `watch_port` `watch_rate` `watch_events` | UDP player-state feed | off (`watch_enable 0`; bundle cfgs set `watch_host "auto"` so `set watch_enable 1` turns it on). See `docs/WATCHLINK.md` |
| `q2_autotier` `q2_overlay_gpu` | markers, not knobs: `misc.c` sets `q2_autotier` to 1 when `hw.model` matched no per-machine overlay and 2 when one ran; each overlay declares the GPU it was measured on in `q2_overlay_gpu` (a lowercase `GL_RENDERER` substring). `R_Init` keeps a mapped profile only when the live renderer matches. On a mismatch it turns `gl_bloom` and `gl_stencilshadow` off, and on mismatched or unmapped machines it enables `gl_glows`/`gl_trans_lighting`/`gl_caustics` on known-capable GPU families (Radeon, GeForce; Rage 128 gets the latter two). Unrecognised GPUs keep the baseline when unmapped and get those three off on a mismatch. Never touches video-mode cvars. `+set q2_autotier 0` disables the probe. Issues #32, #79 | consumed (0) after `R_Init` |

Stock cvars carrying per-machine values: `gl_picmip`, `gl_round_down`,
`gl_texturemode`, `gl_shadows`, `gl_stencilshadow`, `gl_dynamic`,
`gl_flashblend`, `gl_anisotropic`, `gl_overbrightbits`, `gl_retexturing`,
`gl_mode` / `gl_customwidth` / `gl_customheight`, `vid_fullscreen`,
`gl_swapinterval`, `cl_maxfps`, `s_khz`.

Every cvar in these configs is confirmed against the engine source
(`grep -rn 'Cvar_Get' yquake2/src/`). **Do not invent cvars**; anything not in
the source is left out.

## A/B one cvar without a rebuild

### Experimental scene resolve

`gl_scene_resolve 1` is an opt-in, latched experiment for native SDL 1.2.
It requests a single-sample window and moves the requested `gl_msaa_samples`
into a full-resolution scene framebuffer, resolving once before bloom. Bloom,
projected shadows and scene antialiasing remain enabled; the HUD and postprocess
run single-sampled. Default is 0 and no machine profile enables it. It is not
archived. Set it before startup, not in a late `exec` file.

The experiment requires EXT framebuffer object, multisample, blit and packed
depth/stencil support, a back-buffer mono context, and the exact requested
scene sample count. Unsupported configurations fail initialization explicitly
rather than silently disabling antialiasing. SDL12-compat is rejected because
it owns its own framebuffer plumbing. This is not a universal replacement for
the existing path and is not enabled on G3/G4/G5 or Apple Silicon profiles.

### Existing draw-time cvars

    EXTRA='+set gl_retexturing 0 +gl_retexturing' scripts/bench.sh <machine> demo1 1024x768 3

`+set` is applied again after the bundle config, so it overrides the profile.
The trailing cvar command prints its effective value. `+cmd` forwards text to
the server and is not a local cvar override in this engine. If the
tweak wins, fold it into `scripts/bundle/autoexec-<machine>.cfg`, redeploy,
re-bench. See `docs/BENCH.md` and ADR 0010.

The generic x86_64 profile uses `gl_bloom -1` to request a measured GPU
default. The renderer enables bloom and partial restoration on GeForce 9400;
other GPUs resolve to off. Mapped profiles and explicit `+set gl_bloom 0/1`
remain authoritative. The measured 1080p result is about 49.9 fps with bloom,
versus 83.8 without it: this default spends speed on a visible effect.

The generic x86_64 profile also requests `gl_stencilshadow -1` and
`gl_clear_combined -1`. GeForce 9400 resolves these to 1, giving projected
monster shadows with a combined depth/stencil clear. Other GPUs resolve to 0;
mapped profiles and explicit command-line 0/1 overrides remain authoritative.
At native 1920x1080 with bloom and requested MSAA2, demo2 measured
44.15-44.75 fps with projected shadows versus 48.50-48.60 with blobs.
Demo1 measured 45.15 versus 49.80. This is a deliberate visual upgrade with
an FPS cost, not an optimization claim. Evidence is under
`benchmarks/experiments/2026-09-22-framebuffer/intel-shadows/`.

## Tuning the caustic look (`gl_caustics`)

**It is a WATER effect and is gated to water.** `R_EmitWaterPolys` draws every
`SURF_DRAWTURB` surface, and lava and slime are warp surfaces too, so an
ungated overlay paints its blue-white net over molten lava. That shipped, and
was reported from hardware on q2dm6 "Lava Tomb": the lava read as pale blue
water while still behaving as lava when you jumped in.

Measured on q2dm6, whose only liquid texture is `e3u1/brlava`, mean RGB over
the lava pool: on (67.6, 36.9, **39.7**) blue shifted, off (71.7, 38.2,
**31.3**) correct orange, fixed (69.4, 44.8, **30.6**). The texture's two
commonest palette indices are RGB(159,47,35) and (155,31,0), so orange is what
the asset itself describes.

The gate is by **exclusion**, `CONTENTS_LAVA | CONTENTS_SLIME`, not by testing
for `CONTENTS_WATER`. Plenty of maps leave the wal's contents field at 0 for
water and set it on the brush instead, so requiring the water bit would
silently drop caustics from surfaces that have them today. `image_t` keeps the
wal contents for this; `LoadWal` used to throw the header away.

The overlay texture is generated procedurally; there is no asset to edit. Tune
`R_InitCausticTexture` in `yquake2/src/refresh/r_misc.c` and rebuild.

- **`caustic_waves[]`**, integer `(a,b)` frequency pairs that are **summed**.
  More pairs or higher numbers give a finer, busier, more irregular net.
  **Keep them integers** or the tile stops wrapping seamlessly. Mixed signs tilt
  ridges different ways, which reads as more organic.
- **`CAUSTIC_POWER`**, vein sharpness. About 2-3 gives thin hard cords, about
  1.3-1.6 a soft broad shimmer. Shipped "K" preset: **1.5**.
- **`CAUSTIC_GAIN`**, overall brightness 0..1. "K": **0.55**; raise toward 1.0
  for a stronger effect.
- Scroll speed and the blue tint live in `R_EmitWaterPolys` (`r_warp.c`): the
  `cscroll` rate, the per-tile texcoord scale (`1/64`), and
  `qglColor4f(0.55, 0.7, 0.8, 1)`.

Sum, not product, see MISTAKES.md for why that distinction matters.

## Feature inventory

Each row is a shipped feature with the commit that landed it. Measured costs
that drove a default are in ADR 0010.

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
| World decals: BSP fragment clipping (KMQuake2 `r_fragment.c` port) + alpha-blended patches, FIFO with fade-out. Texcoord origin from the **actual impact point**, not the fragment centroid, so the texture centres on the hole regardless of clip geometry. `GL_CLAMP_TO_EDGE` so alpha-0 edges do not bleed. Per-impact radii: bullet 6, blood/greenblood 8, blaster 10, grenade 24, rocket 28, big 36. Hooks: `TE_GUNSHOT`/`SHOTGUN`/`BULLET_SPARKS`, `TE_BLOOD`, `TE_GREENBLOOD`, `TE_BLASTER`/`BLUEHYPERBLASTER`, `TE_*_EXPLOSION` | `gl_decals` `gl_decal_max/life/fade` | see table above | `5c78ca6` + `ffc599d` + `e891163` |
| Latent 5.11 `R_FindImage` NULL-deref fix: the `.tga` and `.jpg` branches called `R_LoadPic(NULL, …)` on missing files, segfaulting in `R_ResampleTexture` |, | all builds | `5c78ca6` |
| MSAA wired through the SDL backend (`SDL_GL_MULTISAMPLE` + `qglEnable(GL_MULTISAMPLE)` at GL init), `CVAR_LATCH` so `vid_restart` picks it up | `gl_msaa_samples` | see table above | `5c54a6e` |
| Per-weapon blast marks: `CL_TraceExplosionSurface` fires six cardinal-axis `CM_BoxTrace` calls from the blast origin and projects the decal onto the nearest solid hit. Rocket `DECAL_BURN` r40 (48 for `_BIG`), grenade `DECAL_SCORCH` r22, plasma `DECAL_PLASMA` r16, BFG `DECAL_BFG` r40, rail `DECAL_RAIL` r7 from the beam direction. Root cause: explosion temp-entity packets carry **no surface normal**, so `cl_tempentities.c:862,926` faked `{0,0,1}` and a wall shot found nothing | `gl_decals` | all decal machines | v2.5.0 |
| Blob shadow for the non-stencil path: one textured `GL_QUADS` on the floor plane instead of the per-triangle projection, radius from the alias frame bbox | `gl_shadows` | machines at `gl_stencilshadow 0` | v2.5.0 |
| `vid_desktopfullscreen` + `GLimp_ForceDesktopFullscreen()` | `vid_desktopfullscreen` | iMac-class | v2.2.0, ADR 0008 |
| watchlink UDP player-state feed | `watch_*` | off by default | v2.5.0, `docs/WATCHLINK.md` |
