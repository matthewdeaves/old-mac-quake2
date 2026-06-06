# Weapon blast-mark decals + non-stencil blob shadow — design

Date: 2026-06-06
Status: design, awaiting user review

Two related visual fixes that share the PIL texture-authoring pipeline
(`scripts/gen-decals.py`) and one build/deploy/bench/screenshot cycle.

- **Part A** — every weapon leaves an appropriate blast/scorch mark on
  walls (today rockets/grenades/plasma/BFG do not mark walls at all).
- **Part B** — fix the blotchy player-model shadow on the non-stencil
  machines (mini-g4 etc.) with a real blob shadow.

---

## Part A — per-weapon blast-mark decals

### Root cause (the rocket bug)

Explosion temp-entity packets carry **no surface normal** (unlike bullets,
which send `MSG_ReadDir`). `cl_tempentities.c` fakes a straight-up normal
(`{0,0,1}`) at lines 862 and 926, so `R_AddDecal` projects the scorch flat
onto the floor. Fired at a **wall**, that vertical projection finds no wall
surface in the fragment clip → no mark. Floor-adjacent blasts happen to work.

### Fix: recover the real surface by tracing

New client helper in `cl_tempentities.c`:

```c
static qboolean
CL_TraceExplosionSurface(const vec3_t origin, float radius,
                         vec3_t out_pos, vec3_t out_normal);
```

- Traces from `origin` outward along the 6 cardinal axes (±X, ±Y, ±Z) a
  distance of `radius` units via `CM_BoxTrace(start, end, vec3_origin,
  vec3_origin, 0, MASK_SOLID)`.
- Keeps the **nearest** solid hit (smallest fraction) — this is the
  "just the main wall hit" behaviour the user chose. Returns its `endpos`
  + `plane.normal`.
- Returns `false` if no surface within `radius` (true airburst) → no decal.

This replaces the hardcoded up-normal at both explosion call sites. The
nearest-hit search naturally picks the wall when the blast is against a
wall, the floor when it's on the ground, the ceiling when it's overhead.

### New decal types + textures

Grow the decal type enum in `src/client/header/ref.h`:

```c
#define DECAL_BULLET      0   /* existing */
#define DECAL_BLOOD       1   /* existing */
#define DECAL_SCORCH      2   /* existing — reused for grenades + blaster */
#define DECAL_GREENBLOOD  3   /* existing */
#define DECAL_BURN        4   /* NEW — rocket: big charred burn */
#define DECAL_PLASMA      5   /* NEW — plasma: hot blue-white scorch */
#define DECAL_BFG         6   /* NEW — BFG: green energy char */
#define DECAL_RAIL        7   /* NEW — railgun: tight punch + scorch ring */
```

New TGAs authored via PIL in `scripts/gen-decals.py`, shipped into the app
bundle `decals/` dir alongside the existing four:

| File | Size | Look |
|---|---|---|
| `burn.tga`   | 128×128 | dark charred core, irregular soot edge, faint radial blast streaks/cracks — the "big old explosion mark" |
| `plasma.tga` |  64×64  | hot blue-white center fading to a scorched ring |
| `bfg.tga`    | 128×128 | sickly-green energy char with radial tendrils |
| `rail.tga`   |  64×64  | tight punch-through hole + thin scorch ring |

128px for the two big ones (more on-screen detail); 64px for the small ones.
All RGBA TGA so the existing `R_FindImage(... it_sprite)` loader picks them up.

### Renderer plumbing (`src/refresh/r_decal.c`)

- Grow `r_decal_textures[4]` → `[8]`; load the four new TGAs in the existing
  boot loader with the same `OK / MISSING` diagnostic log.
- No change to FIFO storage, fragment clipping, per-machine `r_decal_max`
  budget, or drawing — new types are just more textures through the existing
  path.

### Per-weapon wiring (`src/client/cl_tempentities.c`)

| Weapon | Event(s) | Decal | Radius | Normal source |
|---|---|---|---|---|
| Rocket  | `TE_ROCKET_EXPLOSION[_WATER]`, `TE_EXPLOSION1[_BIG/_NP]` | `DECAL_BURN`   | 40 (48 for `_BIG`) | trace |
| Grenade | `TE_GRENADE_EXPLOSION[_WATER]`, `TE_EXPLOSION2`          | `DECAL_SCORCH` | 22 | trace |
| Plasma  | `TE_PLASMA_EXPLOSION`                                    | `DECAL_PLASMA` | 16 | trace |
| BFG     | `TE_BFG_EXPLOSION`, `TE_BFG_BIGEXPLOSION`                | `DECAL_BFG`    | 40 | trace |
| Rail    | `TE_RAILTRAIL` endpoint                                  | `DECAL_RAIL`   |  7 | `normalize(start-end)` (no trace needed) |
| Bullets/shotgun/blaster/hyperblaster | (unchanged) | already works | — | packet `dir` |

Each call guarded by `if (re.R_AddDecal)` like the existing ones, and (for the
traced weapons) `if (CL_TraceExplosionSurface(...))`.

### Out of scope (unchanged from original DECALS_PLAN)

Decals on alias models; decals on moving brushes; network-replicated decals;
decal batching. Multi-surface corner scorching (user chose single nearest hit).

---

## Part B — non-stencil blob shadow

### Root cause (the mini-g4 blotchy shadow)

Confirmed by screenshot compare (`/tmp/shadowdbg/g5-04.png` clean vs
`g4-12.png` blotchy) + code + per-machine configs:

- `R_DrawAliasShadow` (`r_mesh.c:427`) projects **every** model triangle flat
  onto the floor. The stencil ops (`GL_EQUAL,1,2` + `GL_INCR`, lines 445-446)
  are the only thing that masks each floor pixel to draw once.
- With `gl_stencilshadow 0`, projected leg/torso/arm triangles overlap and
  each re-blends at α=0.5 → compounding dark blotches = the artifact.
- The G5 looks clean because `gl_stencilshadow 1` (benched 2026-05-31: zero
  fps cost on the 9600/Leopard driver).
- **Every** `gl_stencilshadow 0` machine has this: mini-g4, quicksilver,
  sawtooth, yosemite, generic x86. User chose: fix all of them.

Re-enabling stencil on the G4 is rejected — the config records a 60% fps drop
(103→40) from the R9200/Tiger driver's `GL_INCR` path, which breaks the fps
floor. The configs *claim* "blob shadow only" for these machines, but no blob
was ever implemented; the fallback is the ugly overlapping silhouette. This
makes that claim true.

### Fix: real blob shadow for the non-stencil path

In `r_mesh.c`, when the shadow is drawn and **not** taking the stencil path
(`!(have_stencil && gl_stencilshadow->value)`), draw a single soft round
shadow quad instead of calling the per-triangle `R_DrawAliasShadow`:

- Reuse the existing shadow matrix/state (already translated to `e->origin`,
  rotated by yaw, blend on, `qglColor4f(0,0,0,0.5)`), but **bind** a soft
  shadow texture (texture stays enabled) and emit one `GL_QUADS` on the floor
  plane at local z = `(lightspot[2] - e->origin[2]) + 0.1`, spanning ±R in
  local X/Y, texcoords 0..1.
- **R** (footprint radius) derived from the alias model's frame bbox
  (`paliashdr` frame `scale`×255 + `translate`, XY extent) so big models get
  big shadows. Clamped to a sane min/max.
- `glDepthMask(0)` + slight `glPolygonOffset` to sit on the floor without
  z-fight; depth test on so it's occluded by geometry correctly.

New texture `decals/shadow.tga` (64×64): opaque-black center, smooth radial
alpha falloff to 0 at the edge. Authored in `gen-decals.py`. Loaded once at
renderer boot via `R_FindImage` (cache an `image_t*` like the decal textures).

Stencil machines (g5, mini-intel) are untouched — they keep the crisp
projected stencil shadow.

### Risk

- Blob is a coarser look than a true silhouette, but it reads as a clean soft
  shadow (matches the cheap-shadow convention) and is strictly better than the
  current blotch. Stencil machines keep the sharp version.
- Footprint radius heuristic may need a tuning constant; validate visually per
  machine.

---

## Shared: build, deploy, verify

1. Regenerate textures: `python3 scripts/gen-decals.py` (adds burn/plasma/bfg/
   rail/shadow TGAs). Verify alpha channels look right (inspect PNGs).
2. Build fat (g3→g4→g5→lion sequential, per the parallel-build hazard rule),
   lipo, `make-dmg.sh` with the byte-identical verify.
3. Deploy to mini-g4 (shadow + decals), imac-g5 (regression: decals on, shadow
   unchanged), yosemite (G3 decal cap + shadow), mini-intel.
4. Verify Part A: in-game, rocket/grenade/plasma/BFG/rail a **wall**, confirm
   the correct mark appears on the wall (not just the floor).
5. Verify Part B: screenshot the same grunt-shadow scene on mini-g4, compare to
   `g5-04.png` — blotch gone, clean blob.
6. Bench demo1/demo2 1024×768 ×3 on mini-g4 + yosemite; guard <5% regression
   vs the recorded baselines. Decals are cheap tris; blob shadow is 1 quad
   (cheaper than the old per-triangle shadow).
7. Smoke test = auto-exiting demo run (never `+map`); also "start a new game"
   for the in-game decal/shadow path.

## Acceptance

- Rocket/grenade/plasma/BFG/rail all leave their distinct mark on a wall
  within seconds; rocket mark is visibly the biggest.
- mini-g4 grunt shadow is a clean soft blob, no blotching; g5 unchanged.
- No >5% fps regression on any benched cell; no fps-floor violation.
- DMG byte-verified; published asset re-verified.
- Before/after screenshots committed to `docs/screenshots/`.
