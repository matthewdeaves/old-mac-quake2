# Tuning the caustic look (`gl_caustics`)

`gl_caustics` is a WATER effect, gated by exclusion of lava and slime. The overlay texture is procedural (`R_InitCausticTexture` in `yquake2/src/refresh/r_misc.c`), so tuning means editing three constants and rebuilding. Brightness is a SUM of wave gratings, not a product (see `docs/mistakes/renderer-features.md`, 2026-05-31 caustics). Cvar and defaults: `docs/CONFIG.md`.

## Why it is gated to water

`R_EmitWaterPolys` draws every `SURF_DRAWTURB` surface, and lava and slime are warp surfaces too, so an ungated overlay paints its blue-white net over lava (seen on q2dm6).

Measured on q2dm6, whose only liquid texture is `e3u1/brlava`, mean RGB over the lava pool: on (67.6, 36.9, **39.7**) blue shifted, off (71.7, 38.2, **31.3**) correct orange, fixed (69.4, 44.8, **30.6**). The texture's two commonest palette indices are RGB(159,47,35) and (155,31,0), so orange is what the asset itself describes.

The gate is by **exclusion**, `CONTENTS_LAVA | CONTENTS_SLIME`, not by testing for `CONTENTS_WATER`. Plenty of maps leave the wal's contents field at 0 for water and set it on the brush instead, so requiring the water bit would silently drop caustics from surfaces that have them today. `image_t` keeps the wal contents for this; `LoadWal` used to throw the header away.

## Tuning constants

Tune `R_InitCausticTexture` and rebuild:

- **`caustic_waves[]`**, integer `(a,b)` frequency pairs that are **summed**. More pairs or higher numbers give a finer, busier, more irregular net. **Keep them integers** or the tile stops wrapping seamlessly. Mixed signs tilt ridges different ways, which reads as more organic.
- **`CAUSTIC_POWER`**, vein sharpness. About 2-3 gives thin hard cords, about 1.3-1.6 a soft broad shimmer. Shipped "K" preset: **1.5**.
- **`CAUSTIC_GAIN`**, overall brightness 0..1. "K": **0.55**; raise toward 1.0 for a stronger effect.
- Scroll speed and the blue tint live in `R_EmitWaterPolys` (`r_warp.c`): the `cscroll` rate, the per-tile texcoord scale (`1/64`), and `qglColor4f(0.55, 0.7, 0.8, 1)`.
