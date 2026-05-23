# Decals — implementation plan

Status: **infrastructure prep done, engine port pending**.

What's already in tree:
- `yquake2/baseq2-extra/decals/{bullet,blood,scorch}.tga` (3 procedural
  TGA decals, 64×64 RGBA, 48 KB total — small enough for R128's 16 MB
  VRAM even with dozens in flight).
- `scripts/gen-decals.py` to regenerate the textures.
- `reference/kmquake2/renderer/r_fragment.c` (327 LOC) as the source
  template for BSP fragment clipping.

What needs to happen, in order. Estimate per step in **engineer-hours**
of focused work, total ≈ 6-8h.

---

## Step 1 — `markFragment_t` struct + ref API (~1h)

**File**: `yquake2/src/refresh/header/local.h` + `src/client/header/ref.h`
+ `src/client/header/refimport.h`.

Add to `local.h`:
```c
#define MAX_DECAL_VERTS  128
#define MAX_DECAL_FRAGS   32

typedef struct {
    int firstPoint;      /* index into the caller's vertex array */
    int numPoints;       /* count of verts in this fragment */
    struct mnode_s *node;/* vis culling */
} markFragment_t;
```

Add to refexport_t in `src/client/header/ref.h`:
```c
int (*R_MarkFragments)(const vec3_t origin, const vec3_t axis[3],
                       float radius, int maxPoints, vec3_t *points,
                       int maxFragments, markFragment_t *fragments);
```

And wire the dispatcher in `r_main.c::R_GetRefAPI`.

---

## Step 2 — port `r_fragment.c` to our tree (~1.5h)

Copy `reference/kmquake2/renderer/r_fragment.c` to
`yquake2/src/refresh/r_fragment.c`. Adapt:

- `r_worldmodel->surfedges` → confirmed match in our `model.h`
- `r_worldmodel->vertexes` → match
- `r_worldmodel->edges` → match
- `surf->checkCount` field — our `msurface_t` may not have this; add
  it if missing (one int field per surface, cheap).
- `VID_Error(ERR_DROP, ...)` → `ri.Sys_Error(ERR_DROP, ...)` to match
  our refimport.
- `cplane_t::type` field — confirm matches our `cplane_t`.

Add `r_fragment.c` to the Makefile's `RENDERER_OBJS` list.

Smoke-test by adding a debug command (e.g. `r_test_marks`) that calls
R_MarkFragments at the player position with a known radius and prints
the result. Verify it returns non-zero fragments inside a level.

---

## Step 3 — client-side decal manager (~2h)

**New file**: `yquake2/src/client/cl_decals.c` (~250 LOC).

Data structures:
```c
typedef struct decal_s {
    float        time;         /* spawn time */
    float        die_time;     /* fade-out completion */
    image_t     *texture;      /* bullet/blood/scorch */
    int          firstPoint;
    int          numPoints;
    /* Per-vertex data laid out separately in cl_decal_verts[] */
} decal_t;

#define CL_MAX_DECALS         128   /* FIFO replacement when full */
#define CL_MAX_DECAL_VERTS    (CL_MAX_DECALS * 16)

extern decal_t   cl_decals[CL_MAX_DECALS];
extern vec3_t    cl_decal_verts[CL_MAX_DECAL_VERTS];
extern int       cl_num_decals;
extern int       cl_decal_head;  /* circular buffer */
```

API:
```c
void CL_ClearDecals(void);                                       /* on map load */
void CL_AddDecal(const vec3_t origin, const vec3_t direction,    /* spawner */
                 float radius, int decal_type);
void CL_RenderDecals(void);                                      /* per-frame draw */
```

`CL_AddDecal` builds the axis basis from `direction`, calls
`R_MarkFragments`, copies the resulting fragments into the next free
slot of `cl_decals[]` (overwriting oldest if full), advances head.

`CL_RenderDecals` is called from `V_RenderView` (after world, before
HUD). For each live decal, GL_ENABLE(GL_BLEND), GL_DEPTH_FUNC(GL_LEQUAL),
glDepthMask(0), bind the texture, glPolygonOffset to bias slightly
toward camera, then for each fragment glBegin(GL_TRIANGLE_FAN) and
emit verts.

Texture lookup at boot: store image_t* pointers for `decals/bullet`,
`decals/blood`, `decals/scorch` via `R_FindImage`. Search the bundle
HD-pak path (`Q2_GetBundleHDPakPath`) first, then `baseq2/decals/`.

Per-machine `r_decal_max` cvar (CVAR_ARCHIVE):
- yosemite (R128 16 MB):  8
- sawtooth (GF2 MX):       16
- quicksilver/mini-g4:     32
- mini-intel/imac:        128

---

## Step 4 — hook impact events (~1h)

**File**: `yquake2/src/client/cl_effects.c`.

Find these existing impact handlers:
- `CL_ParticleEffect` — generic shower of particles at impact point
  → add bullet decal if normal magnitude > 0
- `CL_BulletExplosion` → bullet decal
- `CL_RocketTrail` ending — rocket explosion → scorch decal
- `CL_GrenadeExplosion` → scorch decal
- `CL_BlasterParticles` → small bullet decal
- `CL_BloodSplatter` (if exists in our code) → blood decal

Each handler already gets `(vec3_t origin, vec3_t dir)`. Call
`CL_AddDecal(origin, dir, radius, type)` once per impact.

---

## Step 5 — render integration (~0.5h)

**File**: `yquake2/src/client/cl_view.c` (or wherever V_RenderView is).

After the engine's `R_RenderFrame` returns and before the HUD render:
```c
CL_RenderDecals();
```

Decals draw via immediate-mode `qglBegin(GL_TRIANGLE_FAN)` for now —
later they can be batched through `r_buffer.c`'s group-draw machinery
if performance demands it.

---

## Step 6 — build + visual test on the fleet (~1h)

1. Rebuild all 3 slices, lipo fat.
2. Deploy to mini-g4 + yosemite + mini-intel.
3. Play a brief snippet on each machine (use `+map base1 +sv_cheats 1`)
   and shoot walls / things to verify decals appear.
4. Bench demo1 1024x768 × 3 on each machine — guard against >5% fps
   regression. Decals are cheap textured tris (each one is 2-12 verts)
   so the cost is dominated by the GL_BEGIN/END call count.
5. Visual screenshot pass via `scripts/screenshot.sh` for the gallery.

---

## Risks + open questions

1. **`mnode_t::children` indexing**: KMQuake2's `R_RecursiveMarkFragments`
   walks children[0..1]. Our `mnode_t` has the same layout. Confirm
   via a quick grep before porting.

2. **`SURF_PLANEBACK` semantics**: KMQuake2 reverses the decal's
   alignment to the plane based on this flag. Confirm we use it the
   same way in our `r_surf.c`.

3. **Decal overlap polygon-Z-fight**: solved by `glPolygonOffset` —
   bias of about -1.0 to -2.0 typically. Tune per-driver if Tiger /
   Panther driver hates `glPolygonOffset` (R128 may; if so, fall back
   to `gl_polygon_offset_fill` cvar OFF and accept some z-fighting).

4. **Bundle vs baseq2 path resolution**: Built-in decals ship inside
   `Quake2.app/Contents/Resources/decals/` via the CFBundle hook we
   already have. User-supplied decals go in `baseq2/decals/`.
   `R_FindImage("decals/bullet.tga")` should hit either. Verify the
   bundle search is wired for the `decals/` subdir specifically (we
   may need to extend `Q2_GetBundleHDPakPath`).

5. **mini-intel GL driver z-fight**: Apple's Lion GMA 950 driver had
   weird `glPolygonOffset` behavior in some kernels. May need a
   `cl_decal_zbias` cvar with per-machine tuning.

6. **Memory accounting**: 128 decals × 16 verts × 12 bytes = 24 KB
   for the vertex pool, plus 128 × ~24-byte struct = 3 KB. Negligible.

---

## Acceptance criteria (per-machine)

- Decals visible on bullet impacts within 5 seconds of map load.
- Decals fade gracefully when count exceeds `r_decal_max` (oldest
  removed first).
- No >5% fps regression on any cell in the bench grid.
- No visual corruption: decals stay attached to walls, don't z-fight
  catastrophically, fade smoothly.
- Screenshot of soldier impact + decals committed to `docs/screenshots/`.

---

## Out of scope for first ship

- **Animated decal textures** (KMQuake2 has these; defer)
- **Decals on alias models** (only world brushes for now)
- **Decal sorting / batching** (one draw call per decal is fine at the
  expected counts)
- **Network-replicated decals** (single-player only)
- **Decals on dynamically-spawned brushes (func_door etc.)** (the
  fragment node-pointer becomes stale when the brush moves; for the
  first ship, just don't decal on moving brushes — check
  `surf->flags & SURF_NOLIGHTMAP` or similar as a cheap proxy).

---

End of plan. Next session: pick up at Step 1 with the textures and
this doc already in tree.
