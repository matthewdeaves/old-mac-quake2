# Next round — execution plan for engine-level work

Written 2026-05-19 after the cfg-level round converged. Cfg-level box of
tools empty (sawtooth flashblend, AF on bottom-of-fleet, OBB4 on the four
multitex boxes all shipped 2026-05-19). What remains is multi-hour engine
work.

This plan is ordered by **(visible-impact / effort)** ratio, tier by tier.
Execute top-down. Each item is bench-gated: a regression >5% on any cell
blocks the commit. Each item lists which cells gain.

Per-machine fps floor reminder:
- yosemite (G3 Rage 128): 20 fps floor — at 31 fps demo1 1024, **margin 11 fps**
- sawtooth (G4 GF2 MX):   60 fps floor — at 67 fps demo1 1024, **margin 7 fps**  
- quicksilver (G4 R9000): 60 fps floor — at 70 fps demo1 1024, **margin 10 fps**
- mini-g4 (G4 R9200):     60 fps floor — at 99 fps demo1 1024, **margin 39 fps**
- mini-intel (Lion GMA):  60 fps floor — at 102 fps demo1 1024, **margin 42 fps**
- imac-2019 (Polaris):    60 fps floor — at 732 fps demo1 1024, **margin 672 fps**

---

## Tier 1 — biggest visible wins (do these first)

### 1.1 Group-draw cherry-pick from yquake2-latest (Phase B #3)

**Source:** `reference/yquake2-latest/src/client/refresh/gl1/gl1_buffer.c`
(~9.5KB) + `GLBUFFER_VERTEX/GLBUFFER_MULTITEX` macros baked into every
call site in `gl1_surf.c`, `gl1_warp.c`, `gl1_draw.c`, `gl1_mesh.c`.

**Why:** The CHANGELOG says: "Group draw call in GL1. This yields huge
performance gains on slow GPUs." Confirmed via code inspection — 5.11's
`R_DrawTextureChains` already groups by texture but the inner per-surface
loop calls `R_DrawGLPoly` which spits `qglBegin(GL_POLYGON) ... qglVertex3fv
... qglEnd` per surface. Each immediate-mode call is a driver round-trip.
On R128 + GF2 MX (drivers from 1999/2000) the per-call cost is dominant.
Same demo can have 200-400 surfaces visible at any time → 200-400 begin/end
pairs per frame, replaced by 1 VBO stream + 1 draw call.

**Per-machine impact prediction:**
- yosemite R128: **+30-100% fps demo1 1024** (the chip is submission-bound;
  this is the bug the yquake2 maintainers said this fix addresses)
- sawtooth GF2 MX: +10-20% fps (also submission-bound)
- quicksilver/mini-g4: +5-10% (modern enough that immediate-mode isn't
  catastrophic)
- mini-intel/imac-2019: <5% (modern GL drivers cache immediate-mode well)

**Scope/effort:** Multi-file refactor. PPC_PLAN.md flags this as hand-port
territory because yquake2-latest renamed `src/refresh/` → `src/client/refresh/gl1/`
and the group-draw work is intermingled with the "Client & GL1 refactor"
commits. Estimated 4-6 hours.

**Risk:** Medium-high. If the buffer's vertex layout is wrong, every
surface renders garbage. Triangulation order matters. Backslide path:
revert commit, no machine ships the change.

**Bench gate:** Demo1 + demo2 × 1024×768 + 640×480 × 3 runs on all 6
machines. Each cell must hold or improve.

**Steps:**
1. Read `gl1_buffer.c` + `gl1_buffer.h` start-to-finish; understand
   `R_SetBufferIndices`, `R_UpdateGLBuffer`, `R_ApplyGLBuffer`.
2. Identify the GLBUFFER_VERTEX/GLBUFFER_MULTITEX macro contract.
3. Port the helper file into `yquake2/src/refresh/r_buffer.c` (NEW).
4. Rewrite `R_DrawGLPoly`, `R_DrawGLFlowingPoly`, `R_DrawGLPolyChain`,
   `R_RenderBrushPoly`, `R_RenderLightmappedPoly`, `R_DrawAlphaSurfaces`,
   `R_EmitWaterPolys`, and `R_DrawParticles2` to feed the buffer instead
   of immediate-mode.
5. Smoke test: walk one level, verify no visual corruption.
6. Full bench grid.

---

### 1.2 stb_image LoadJPG port + enable WITH_RETEXTURING

**Source:** `reference/yquake2-latest/src/client/refresh/files/stb_image.h`
(public domain, 278KB single-header) and `stb.c` wrapper.

**Why:** 5.11's `LoadJPG` uses libjpeg. libjpeg isn't installed on the
mini-intel build host. As a result, `scripts/build.sh:110` `sed`s
`WITH_RETEXTURING=yes` → `=no`, which `#ifdef`-disables the entire hi-res
texture loading code path. The cfg lines `set gl_retexturing 1` on
quicksilver, mini-g4, mini-intel, imac-2019 are **silent no-ops today**.
With stb_image replacing libjpeg, WITH_RETEXTURING can be ON across all
3 slices with zero external dependencies.

**Per-machine impact prediction:**
- Visible impact today: **ZERO** (no HD texture pack shipped). 
- Latent unlock: the user can drop in any TGA/JPG/PNG pack post-deploy
  and it lights up everywhere with retex=1. Sharp 1024×1024 textures on
  walls vs the 256×256 originals — dramatic on Polaris 20.

**Scope/effort:** Bounded ~2 hours.

**Risk:** Low. The new LoadJPG has the same signature `void
LoadJPG(char *origname, byte **pic, int *width, int *height)`. Drop-in.
stb_image is mature and used in many shipping engines.

**Steps:**
1. Copy `stb_image.h` to `yquake2/src/refresh/files/stb_image.h`.
2. Rewrite `yquake2/src/refresh/files/jpeg.c` to use stb_image instead
   of libjpeg's `jpeg_decompress_struct`. Preserve `LoadJPG` signature.
3. Remove `-framework libjpeg` from `yquake2/Makefile` (or whole linker
   line in the `WITH_RETEXTURING=yes` block).
4. Modify `scripts/build.sh:110` to NOT sed out `WITH_RETEXTURING=yes`.
5. Build g3 + g4 + lion (all three need to compile with retex).
6. Verify cfg cvars now create real `gl_retexturing` cvar.
7. Bench all 6 to verify no regression (without HD pack, retex code
   path looks for replacements and falls back to .pcx/.wal cleanly).
8. (Optional follow-up) source a free HD pack (e.g. NeuralUpscale or
   the public-domain CDQ HD pack) and verify visual lift on quicksilver+.

---

### 1.3 yquake2-latest gl1_particle_square + GL_POINTS path verification

**Source:** `reference/yquake2-latest/src/client/refresh/gl1/gl1_main.c`
particle drawing code.

**Why:** 5.11's `R_DrawParticles2` (the non-pointsprite fallback) draws
3 immediate-mode vertices per particle. Round particles via point sprites
(`gl_ext_pointparameters 1`) are cheap on modern chips but yosemite has
this OFF because R128's point sprite ext is buggy. So yosemite goes
through R_DrawParticles2 — the worst-case path. `gl1_particle_square 1`
on yquake2-latest replaces the round-blit with a single GL_POINTS draw
of square particles. Skips the alpha-test, skips per-particle triangle
emission.

**Per-machine impact prediction:**
- yosemite: +5-10% in particle-heavy moments (rocket trails, explosions)
- sawtooth/quicksilver/mini-g4: <2% (point sprites already work)
- mini-intel/imac-2019: <1%

**Scope/effort:** Small. ~1 hour.

**Risk:** Low. Square particles vs round is a visual preference, not a
correctness change.

**Steps:**
1. Add `gl_particle_square` cvar (CVAR_ARCHIVE, default 0).
2. In `R_DrawParticles`, dispatch: square path = single GL_POINTS draw
   (no point-sprite ext needed); round path = existing
   pointparameters or triangle-billboard fallback.
3. Add to autoexec-yosemite.cfg with default 1 (force square on R128).
4. Bench yosemite + sawtooth.

---

## Tier 2 — visual Phase C ports (KMQuake2 cherry-picks)

### 2.1 Decals (Phase C #3) — r_fragment.c

**Source:** `reference/kmquake2/renderer/r_fragment.c` (~8KB).

**Why:** Bullet impacts, blood splatter, scorch marks on walls. Free
visual richness with no perf cost (decals fade after N seconds, count
capped). Fixed-function compatible — fits all 6 chips.

**Per-machine impact prediction:** Visible visual win on every machine.
Decals are bounded by `r_decal_max` cvar. Cost: a few extra surfaces per
frame, negligible.

**Scope/effort:** Medium. KMQuake2's decal subsystem has its own state
manager. ~3-4 hours porting + bench.

**Risk:** Medium. Decal lifetime management is its own subsystem with
its own data structures. Needs care to integrate with our texture chains.

**Per-machine defaults:**
- yosemite: r_decal_max 8 (fillrate-limited)
- sawtooth: r_decal_max 16
- quicksilver/mini-g4/mini-intel: r_decal_max 32
- imac-2019: r_decal_max 128 (or uncapped)

---

### 2.2 Stencil shadows (Phase C #8) — alias model true shadows

**Source:** `reference/kmquake2/renderer/r_alias_md2.c` (and surrounding).

**Why:** Real volumetric shadows for enemies/player projected onto
walls/floor, replacing the simple `gl_shadows` blob. Requires stencil
buffer (SDL_GL_STENCIL_SIZE=8 already set in refresh.c).

**Per-machine impact prediction:**
- yosemite: probably SKIP — R128 stencil support is iffy in 10.3.9 driver.
- sawtooth: SKIP — GF2 MX has stencil, but cost might break the 60 fps
  floor on 500 MHz G4 (per-light stencil pass).
- quicksilver/mini-g4: ON — Radeon 9000/9200 have full stencil.
- mini-intel: cautious ON — GMA 950 has stencil but driver is unreliable.
- imac-2019: ON.

**Scope/effort:** Medium-high. ~4-5 hours.

**Risk:** Medium. Stencil state interacts with everything; visual glitches
likely on first pass.

---

### 2.3 Alpha-test surfaces with lightmaps (Phase C #4)

**Source:** `reference/kmquake2/renderer/r_surface.c` modifications.

**Why:** Textures with alpha-cutout regions (grates, vegetation,
chain-link) currently fall through to non-lightmapped path → look dark
or wrong. KMQuake2 routes them through a special alpha-tested lightmap
blend that preserves shading.

**Per-machine impact prediction:** Visual correctness win, no fps cost.
Fixed-function compatible.

**Scope/effort:** Low-medium. ~2-3 hours.

---

### 2.4 Transparent surfaces with lightmaps (Phase C #7)

**Source:** `reference/kmquake2/renderer/r_surface.c` SURF_TRANS33/66 changes.

**Why:** Glass + force fields currently render without lightmaps in 5.11
GL1. Looks "floating" in the level. KMQuake2 adds a blend mode that
preserves lightmap modulation on transparent surfaces.

**Per-machine impact prediction:** Visual win. Cost: one extra texture
unit on multitex boxes (free), or one extra pass on dual-pass boxes
(small fps cost).

**Scope/effort:** Low-medium. ~2 hours.

---

### 2.5 Bloom (Phase C #5) — r_bloom.c + r_arb_program.c

**Source:** `reference/kmquake2/renderer/r_bloom.c` (21KB) +
`r_arb_program.c` (10KB).

**Why:** Bright surfaces get a soft glow halo. Big visual upgrade,
especially on dlight events. Requires `ARB_fragment_program`.

**Per-machine impact prediction:**
- yosemite: SKIP — R128 has no fragment program. 
- sawtooth: SKIP — GF2 MX has no fragment program.
- quicksilver R9000 Pro: ON (R9000 Pro has ARB_fragment_program;
  base R9000 may not). Verify driver report.
- mini-g4 R9200: SKIP — R9200 specifically dropped fragment_program (it's
  a R8500 variant). Verify.
- mini-intel GMA 950: SKIP — no ARB_fragment_program.
- imac-2019 Polaris: ON.

**Scope/effort:** High. ~6-8 hours including bench.

**Risk:** High. ARB shader debugging on retro GPUs is painful.

---

### 2.6 Quake2maX particle effects (Phase C #6)

**Source:** `reference/kmquake2/renderer/r_particle.c` (30KB).

**Why:** Richer particle system — proper smoke, blood spray, sparks.
Visual replacement for Q2's spartan particle palette.

**Per-machine impact prediction:** Big visual lift on every machine.
KMQuake2 has a quality dial (`cl_particles_quality` low/med/high) so we
can per-machine tune cost.

**Scope/effort:** High. The 30KB particle code is its own subsystem.
~5-6 hours.

**Risk:** Medium. Particles touch the client + renderer boundary;
integration with our render pass is non-trivial.

**Per-machine defaults:**
- yosemite: low
- sawtooth: low
- quicksilver: med
- mini-g4: high
- mini-intel: high
- imac-2019: high

---

## Tier 3 — code-level optimizations (AltiVec + SIMD)

### 3.1 AltiVec R_BuildLightMap scaled-add loops

**Target:** `yquake2/src/refresh/r_light.c:541-595`. Per-luxel
byte→float scaled-add. Two loops (nummaps==1 and nummaps>1).

**Why:** Quicksilver/mini-g4 are CPU-bound on this loop during
dlight-heavy scenes (rocket explosions, BFG). Vectorizing 4 luxels per
iteration could give 2-3× speedup on that hot loop.

**Per-machine impact prediction:**
- yosemite (no AltiVec): zero (G3 has no AltiVec)
- sawtooth (AltiVec but uses flashblend): zero (path not hit)
- quicksilver (AltiVec 7450): +3-7% demo1 in dlight scenes
- mini-g4 (AltiVec 7447A): +3-7%
- mini-intel/imac-2019 (no AltiVec, but SSE available): could add x86 path
  separately for +similar gains, but boxes are already at 100+/700+ fps
  so the win is irrelevant.

**Scope/effort:** Medium. ~4-5 hours including AltiVec quirks and bench.

**Risk:** Medium. AOS RGB layout is hostile to vectorization. Need
careful unaligned loads (vec_lvsl/vec_lvsr) or layout change.

**Steps:**
1. Wrap new code in `#ifdef __ALTIVEC__` so it compiles only on G4
   slice (build.sh g4 has `-maltivec`).
2. Process 4 luxels per iteration: load 12 bytes of lightmap, unpack
   to 3 vec_float4 registers, multiply by broadcast scale pattern,
   store to 12 floats of s_blocklights.
3. Handle the size%4 tail in scalar.
4. Validate visually identical output (no shimmer in lightmaps).
5. Bench quicksilver + mini-g4 demo3 (most dlight-heavy).

---

### 3.2 AltiVec R_LerpVerts

**Target:** `yquake2/src/refresh/r_mesh.c:49-82`. Per-vertex alias model
lerp between two frames.

**Why:** Every visible enemy + player + weapon costs `num_xyz` lerps per
frame. demo1 has ~5-10 visible models in busy scenes × 100-500 verts
each. Hot on the CPU side.

**Per-machine impact prediction:**
- quicksilver: +2-5%
- mini-g4: +2-5%
- yosemite: zero (no AltiVec)
- sawtooth: +2-5% (AltiVec available, this path is hot)

**Scope/effort:** Medium. ~3-4 hours.

**Risk:** Medium. Same AOS-byte-stride issue as R_BuildLightMap.

---

### 3.3 SSE2 path mirroring AltiVec for Intel

**Target:** Same loops as 3.1/3.2 but with `<emmintrin.h>` SSE intrinsics.

**Why:** mini-intel + imac-2019 already at 100/700 fps. Win irrelevant
unless we hit a CPU bottleneck on the modern boxes after Tier 1/2 lands.
**Skip unless bench shows CPU-bound.**

---

## Tier 4 — engine plumbing

### 4.1 MSAA via SDL_GL_MULTISAMPLE

**Target:** `yquake2/src/backends/sdl/refresh.c:214` — add
`SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1)` +
`SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, gl_msaa_samples->value)`
before SDL_SetVideoMode. Plus `glEnable(GL_MULTISAMPLE)` post-context.

**Why:** Polaris 20 (imac-2019) can do 8x MSAA at zero perf cost. Removes
the polygon-edge aliasing that's the giveaway of fixed-function GL.

**Per-machine impact prediction:**
- imac-2019: 8x MSAA, dramatic visual lift, ~0% fps cost.
- mini-intel GMA 950: try 2x; the GMA driver supports it but slowly.
- quicksilver/mini-g4: try 2x; R9000/R9200 should handle 2x cheaply.
- sawtooth GF2 MX: SKIP — chip supports MSAA via SGIS_multisample but
  Mac driver may not expose it.
- yosemite R128: SKIP — no MSAA.

**Complication:** First-boot the autoexec hasn't fired when SDL inits.
The MSAA cvar value at SDL_GL_SetAttribute time would be 0 (default).
Two solutions:
- (a) Autoexec writes the cvar; engine issues `vid_restart` at end of
  autoexec; second pass picks up MSAA. One visible flash on first boot.
- (b) Read the cvar from a special early-boot file (before SDL init).

Option (a) is simpler. On subsequent boots config.cfg has the value
already so no flash.

**Scope/effort:** Medium. ~2-3 hours including the vid_restart wiring.

**Risk:** Medium. SDL 1.2's MSAA support on Tiger varies by chip; could
fail to create context, fallback path needed.

---

### 4.2 gl1_minlight cvar (yquake2-latest port)

**Target:** Latest's `gl1_minlight` — minimum light value applied in
R_BuildLightMap so dark spots don't go pitch black.

**Why:** Q2's lightmaps drop to actual black in many corners. With
minlight=8 or 16, even unlit corners have faint visibility. Helps
gameplay (see enemies in shadow) and looks cleaner.

**Per-machine impact prediction:** Visual win, no fps cost.

**Scope/effort:** Low. ~1 hour. Read minlight[256] LUT from r_main.c in
latest, port to 5.11's R_BuildLightMap.

---

### 4.3 gl_farsee 1 enable on imac-2019 (and big-VRAM boxes)

**Target:** existing `gl_farsee` cvar in r_main.c:995 (CVAR_LATCH).

**Why:** Q2's BSP traversal culls distant geometry by default for
fillrate reasons. `gl_farsee 1` disables the distance cap → see the
whole level at once. Polaris 20 doesn't care about fillrate.

**Complication:** CVAR_LATCH means it requires `vid_restart` after
setting. Same vid_restart-at-end-of-autoexec mechanic as MSAA.

**Scope/effort:** Low (autoexec only, IF vid_restart mechanic exists).
But the vid_restart hook needs to be wired separately.

---

## Tier 5 — small wins from PPC_PLAN.md inventory

### 5.1 GL1 gamma correction (Phase B #5)

**Source:** yquake2-latest GL1 gamma path. 5.11 uses SDL_SetGamma
which is hit-or-miss on Tiger; the GL1 software gamma is more reliable.

**Effort:** ~1 hour.

**Win:** Per-machine gamma calibration that doesn't flicker the display.

---

### 5.2 Multitex bugfix for multi-light-style surfaces

**Source:** yquake2-latest commit, addresses "Fixed GL1 multitexturing
in surfaces using multiple light styles." Bug shows up on flickering
torch surfaces.

**Effort:** ~1 hour. Visual correctness, not fps.

---

### 5.3 Yosemite quality tier expansion (cfg-only, requires bench)

After Tier 1 group-draw lifts yosemite fps headroom:
- Try `gl_picmip 0` (full texel detail) — bench, check VRAM
- Try `gl_texturemode GL_LINEAR_MIPMAP_LINEAR` (trilinear) — bench
- Try `gl_round_down 0` — bench

**Effort:** Each is one cfg edit + bench = 5 minutes per knob. Do AFTER
Tier 1 group-draw lands and we know the new headroom.

---

## Suggested execution order

1. **Day 1 (~6h):** Tier 1.1 group-draw. Biggest yosemite win. Land
   commit, bench grid, iterate on visual bugs.
2. **Day 1 evening (~2h):** Tier 1.2 stb_image. Unlocks WITH_RETEXTURING
   for any future HD pack. Bench-only-for-regression.
3. **Day 2 (~3h):** Tier 1.3 particle_square + Tier 4.2 minlight + Tier
   5.1 GL1 gamma + Tier 5.2 multitex bugfix. Batch of small cherries.
4. **Day 2 evening (~2h):** Tier 5.3 yosemite quality tier expansion now
   that group-draw lifted fps.
5. **Day 3 (~5h):** Tier 2.3 alpha-test lightmaps + 2.4 transparent
   lightmaps. Visual correctness wins.
6. **Day 4 (~4h):** Tier 2.1 decals. Big visual richness lift.
7. **Day 5 (~3h):** Tier 4.1 MSAA with vid_restart. imac-2019 polish.
8. **Day 6 (~5h):** Tier 2.2 stencil shadows. Real alias-model shadows
   on capable boxes.
9. **Tier 2.5 bloom + 2.6 particles + Tier 3 AltiVec** — defer until
   first 8 days land. By that point fps headroom and remaining items
   will be clearer.

## Bench cadence per item

Same as the round we just shipped:
1. Code change → smoke bench on dirty tree (one machine, one resolution,
   3 runs).
2. If no regression → commit code + bench row + raw logs.
3. After commit → full grid (6 machines × 2 demos × 2 res × 3 runs).
4. Update `PPC_PLAN.md` live feature inventory with new commit SHA.

## Risk gating

Block any commit if:
- Any cell drops >5% fps from previous round's row
- yosemite drops below 20 fps demo1 1024
- Any G4 box drops below 60 fps demo1 1024
- Visual regressions (corruption, missing surfaces, wrong colors) on
  any machine

## Open questions for next session

1. Should we source an HD texture pack for testing retex post-Tier 1.2?
   (Free packs exist: NeuralUpscale, CDQ, Quake2-RTX assets.)
2. Should we install MacPorts on mini-intel to enable libjpeg/libpng/
   libtiff for richer image support? (Probably no — stb_image is
   sufficient.)
3. Bloom on quicksilver — does R9000 Pro driver on Tiger actually expose
   ARB_fragment_program? Need to bench-run a probe before investing.
4. Are we willing to break first-boot UX (one vid_restart flash) for
   MSAA and gl_farsee? If no, we need a different cvar-init mechanic.

---

End of plan. ~30-40 hours of work distributed across the tiers. Each
tier delivers visible gains independently — no need to do them all to
ship a meaningful improvement.
