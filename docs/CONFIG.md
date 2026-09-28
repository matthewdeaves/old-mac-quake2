# Runtime config reference

The cvar reference for the fork's custom cvars and per-machine defaults, plus how to A/B a cvar without a rebuild. The three-layer bundle config, its call-site constraint and the machine map are in **ADR 0007**. Files: `scripts/bundle/autoexec-*.cfg`, `yquake2/src/common/misc.c` (`Q2_ExecConfigFromBundle`).
Every cvar here is confirmed against the engine source (`grep -rn 'Cvar_Get' yquake2/src/`); **do not invent cvars**.
Sections: Custom cvars, Capability tier, Stock cvars, A/B one cvar, Scene resolve, Measured GPU defaults. Feature inventory with commits: `docs/FEATURES.md`. Caustic tuning: `docs/CAUSTICS.md`.

## Custom cvars

Added on top of stock yquake2 5.11:

| cvar | what | default per machine |
|---|---|---|
| `gl_fog` (+ `_mode` `_start` `_end` `_density` `_red/green/blue`) | cvar-driven `GL_FOG` | on (all); linear, far 2048-4096 |
| `gl_waterwarp` | underwater frustum sine-warp, magnitude 0..1 | 1 (all), one `sin()` per frame, only when `RDF_UNDERWATER` |
| `gl_decals` `gl_decal_max` `gl_decal_life` `gl_decal_fade` | KMQuake2 world decals | on; cap 8 (G3), 16 (sawtooth), 32 (qs/mg4), 64 (mini-intel), 128 (imac-2019) |
| `gl_msaa_samples` | MSAA, `CVAR_LATCH` (0/2/4/8/16) | 0 G3+sawtooth+mini-intel, 2 qs/mg4, 2 imac-g5, 8 imac-2019 |
| `gl_lightmap_subrect` | dirty-column-only dynamic lightmap upload | 1 (all); no-op when `gl_dynamic 0` |
| `gl_groupdraw` | batched `qglDrawElements` dispatch (+ `glLockArraysEXT` CVA) | 1 on G4+ and x86, 0 on G3 (no benefit, small cost) |
| `gl_minlight` | lightmap LUT clamp | 16 yosemite, 8 sawtooth, 0 elsewhere |
| `gl_skydistance` | sky box size | 2300 (vanilla) |
| `gl_particle_square` | force the `GL_POINTS` path | 1 on yosemite (R128 has no point parameters) |
| `gl_pointsprites` | `GL_ARB_point_sprite` particles | per-machine |
| `r_2D_unfiltered` | HUD pics on `GL_NEAREST` | 1 on all six (all use trilinear) |
| `gl_glows` | sphere-map energy shell glow | on multitex, off G3 + sawtooth |
| `gl_trans_lighting` | lightmapped glass/grates, latched at map load | on multitex, off G3 + sawtooth |
| `gl_caustics` | water-surface caustic overlay. **Water only**: skips lava and slime (`docs/CAUSTICS.md`) | on multitex, off G3 + sawtooth |
| `gl_zfix` | polygon-offset coplanar surfaces | on (all) |
| `gl_clear_combined` | clear requested depth/stencil/colour buffers together | 1 on measured mini-G4 and G3 profiles and GeForce 9400 auto-default; 0 elsewhere |
| `gl_bloom_fastrestore` | restore only the overwritten bloom workspace corner, for any view size: the bloom capture spans the whole window, border included (#80) | 1 with the measured GeForce 9400 bloom auto-default; 0 elsewhere |
| `gl_farsee` | extended far clip, `CVAR_LATCH` | on ppc7400/ppc970/x86_64/arm64, off ppc750/i386 (#24) |
| `gl_bloom` (+ `_alpha` `_darken` `_size`) | fixed-function light bloom | on for tuned G5 dual, imac-2019 and arm64 profiles; off on G3/G4 and generic Intel. Apple Silicon measured 264.55 fps at 1920x1080 with bloom, 4x MSAA and desktop-fullscreen; evidence: `benchmarks/experiments/2026-09-12-bloom-readback/` |
| `vid_desktopfullscreen` | native-res same-mode fullscreen capture | on iMac-class (`ppc970` baseline + `imac-g5`); off elsewhere. **The only R300/Leopard-safe fullscreen, ADR 0008** |
| `watch_enable` `watch_host` `watch_port` `watch_rate` `watch_events` | UDP player-state feed | off (`watch_enable 0`). See `docs/WATCHLINK.md` |
| `q2_autotier` `q2_overlay_gpu` | markers, not knobs: see Capability tier | consumed (0) after `R_Init` |

## Capability tier

`q2_autotier` and `q2_overlay_gpu` are markers. `misc.c` sets `q2_autotier` to 1 when `hw.model` matched no per-machine overlay and 2 when one ran; each overlay declares the GPU it was measured on in `q2_overlay_gpu` (a lowercase `GL_RENDERER` substring). `R_Init` keeps a mapped profile only when the live renderer matches.
- On a mismatch it turns `gl_bloom` and `gl_stencilshadow` off.
- On mismatched or unmapped machines it enables `gl_glows`/`gl_trans_lighting`/`gl_caustics` on known-capable GPU families (Radeon, GeForce; Rage 128 gets the latter two). Unrecognised GPUs keep the baseline when unmapped and get those three off on a mismatch.
- It never touches video-mode cvars. `+set q2_autotier 0` disables the probe. Issues #32, #79.

## Stock cvars

Stock cvars carrying per-machine values: `gl_picmip`, `gl_round_down`, `gl_texturemode`, `gl_shadows`, `gl_stencilshadow`, `gl_dynamic`, `gl_flashblend`, `gl_anisotropic`, `gl_overbrightbits`, `gl_retexturing`, `gl_mode` / `gl_customwidth` / `gl_customheight`, `vid_fullscreen`, `gl_swapinterval`, `cl_maxfps`, `s_khz`.

## A/B one cvar

Without a rebuild, using existing draw-time cvars:

    EXTRA='+set gl_retexturing 0 +gl_retexturing' scripts/bench.sh <machine> demo1 1024x768 3

`+set` is applied again after the bundle config, so it overrides the profile. The trailing cvar command prints its effective value. `+cmd` forwards text to the server and is not a local cvar override in this engine. If the tweak wins, fold it into `scripts/bundle/autoexec-<machine>.cfg`, redeploy, re-bench. See `docs/BENCH.md` and ADR 0010.

## Scene resolve

`gl_scene_resolve 1` (latched, not archived; set it before startup) requests a single-sample window and renders the scene into an FBO with `gl_msaa_samples`, resolving once before bloom. The HUD and postprocess run single-sampled. It needs native SDL 1.2 (not sdl12-compat) and EXT FBO, multisample, blit and packed depth/stencil. Without them it logs why and continues without antialiasing. Only the imac-2019 profile enables it (8x: 176 fps vs 74 for window 8x with bloom, #69).

## Measured GPU defaults

The generic x86_64 profile uses `gl_bloom -1` to request a measured GPU default. The renderer enables bloom and partial restoration on GeForce 9400; other GPUs resolve to off. Mapped profiles and explicit `+set gl_bloom 0/1` remain authoritative. Measured 1080p: about 49.9 fps with bloom versus 83.8 without: this default spends speed on a visible effect.

It also requests `gl_stencilshadow -1` and `gl_clear_combined -1`. GeForce 9400 resolves these to 1 (projected monster shadows with a combined depth/stencil clear); other GPUs resolve to 0; mapped profiles and explicit command-line 0/1 overrides remain authoritative. At native 1920x1080 with bloom and requested MSAA2, demo2 measured 44.15-44.75 fps with projected shadows versus 48.50-48.60 with blobs; demo1 45.15 versus 49.80. This is a deliberate visual upgrade with an FPS cost, not an optimization claim. Evidence: `benchmarks/experiments/2026-09-22-framebuffer/intel-shadows/`.
