# Mistakes log — things we tried that were bad

Append-only record of changes that landed in tree (or were attempted)
and turned out to be wrong, harmful, or otherwise misjudged. Each
entry exists so future rounds don't re-litigate the same idea on
incomplete information.

Format: date, what we tried, what went wrong, what the fix was, what
we learned. Newest at the top.

See `~/quakespasm/MISTAKES.md` for cross-applicable lessons from the
sister project — especially anything about benchmark concurrency
(don't run g3+g4 builds in parallel; don't run bench.sh legs
concurrently from one shell), and SDL framework dyld install_name
quirks.

---

## 2026-05-23 — `gl_stencilshadow 1` on Tiger ATI drivers regresses 60% fps

**What we tried:** Enabled `gl_stencilshadow 1` in autoexec for sawtooth
(GF2 MX), quicksilver (R9000), mini-g4 (R9200), and mini-intel (GMA 950).
The hope was that the existing `R_DrawAliasShadow` stencil path
(`GL_EQUAL, 1, 2` + `GL_INCR`) would compose overlapping monster
shadows without double-darkening, given that 8-bit stencil is requested
via `SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8)`.

**What went wrong:** On mini-g4 (R9200, ATI Tiger driver) demo2 1024×768
fps dropped from 103.6 → 40.6 — a **60% regression**. The R9200's
per-fragment `GL_INCR` stencil op runs on a very slow driver code
path; the bench scene with many monsters hits it every frame.

**Fix:** Reverted `gl_stencilshadow` to 0 on all four PPC + Intel
slow-stencil machines. Left blob shadows (`gl_shadows 1`) ON since
those run at the existing fillrate cost. imac-2019 (Polaris) keeps
`gl_stencilshadow 1` — plenty of headroom there.

**Lesson:** 8-bit stencil being *requested* doesn't mean the per-frag
op path is fast. Tiger-era ATI drivers fall off a cliff on stencil
INC. The `have_stencil` flag in r_mesh.c only checks if stencil bits
were granted, not if the path is performant — so it can't guard for
this. Bench-validate per machine before enabling any stencil-test
feature on 1999-2007 GPUs.

---

## 2026-05-23 — Multitexture state leaks into ad-hoc draw passes on GMA 950

**What we tried:** Wrote `R_DrawDecals` in `r_decal.c` to render world
decals after `R_DrawAlphaSurfaces`. The path bound the decal texture
to TMU0, called `R_TexEnv(GL_MODULATE)`, and drew alpha-blended quads
with `qglColor4f(1, 1, 1, alpha)`. Worked correctly on yosemite
(R128, no multitex) and mini-g4 (R9200) — dark decal texture renders
as dark bullet holes.

**What went wrong:** On mini-intel (GMA 950, Lion driver), the same
build rendered minigun decals as **light grey discs** instead of
dark bullet holes. The shape was right (rotation, falloff, position
all correct), only the colour was wrong. Reported by the user
playing on the physical machine: "the bullet marks on walls appear
as light grey from the mini gun — not quite right".

**Root cause:** `R_DrawWorld` leaves multitexture ENABLED with TMU1
holding the lightmap + an overbright combiner state (`GL_RGB_SCALE_EXT 4`
when `gl_overbrightbits 4`). The R9200 / Rage 128 drivers apparently
reset TMU1's combine state when TMU0 binds a new texture; the GMA 950
Lion driver does NOT. So `R_TexEnv(GL_MODULATE)` set TMU0's env, but
TMU1 kept applying the bright lightmap, modulating the dark decal
texel up to grey.

**Fix:** Explicit `R_EnableMultitexture(false)` at the start of
`R_DrawDecals` to guarantee single-texture state. Cheap (one extra
`qglDisable(GL_TEXTURE_2D)` on TMU1).

**Lesson:** GL state cleanup is the caller's responsibility. Any
ad-hoc draw pass that runs after `R_DrawWorld` MUST explicitly disable
multitexture if it expects single-texture semantics — relying on
TMU0's env to override TMU1 is driver-dependent. The "it works on
PPC" sanity check is not sufficient for a state-machine bug; test on
GMA 950 / Intel before declaring done.

---

## 2026-05-23 — AltiVec R_BuildLightMap is net-negative on Q2 too

What we tried: AltiVec port of R_BuildLightMap's `scale != 1.0F` paths
(both nummaps==1 assign and nummaps>1 accumulate variants). Output
stride is 3 floats — incompatible with `vec_st`'s 16-byte aligned
contract, so each loop body builds 16-byte aligned stack temps for
input + accumulator, vec_madd, vec_st to a temp, scalar extract of
lanes 0-2 to bl[]. The sister project (`~/quakespasm/Quake/r_brush.c`)
measured this class of work as net-neutral on QuakeSpasm; the hope
was Q2's larger lightmap surfaces would tip it positive.

What went wrong:
  - mini-g4 1024 demo1: 101.25 → 98.95 fps (−2.3%) with the AltiVec
    code on the gl_dynamic 1 path that actually exercises it.
  - sawtooth at gl_dynamic 0 (autoexec default): no exercise of the
    code, no signal.
  - sawtooth at gl_dynamic 1 (autoexec-edited unlock attempt):
    14.70 fps demo1 1024. Slightly WORSE than the 15.25 fps documented
    in the 2026-05-19 "Lightmap subrect doesn't unlock dlights on
    sawtooth either" entry. So the dlight path is still untouchable
    on GF2 MX + AGP1999 + 500 MHz 7400.

Root cause is the per-iteration setup overhead. AltiVec needs aligned
input vectors, and bl's 3-float stride means destination is non-
aligned every iteration. The scalar-extract-after-vec_st pattern
trades one parallel `vec_madd` (cheap) for one extra `vec_ld` (per
input), one extra `vec_st` to a stack temp (per output), and three
scalar loads from that temp. Net per-luxel cost exceeds the scalar
3 fmul + 3 fmadd.

Fix: revert all AltiVec code in R_BuildLightMap, drop the
`__attribute__((aligned(16)))` on s_blocklights (no longer needed),
restore sawtooth's autoexec to `gl_dynamic 0 + gl_flashblend 1`.

What we learned:
  1. **AltiVec on AOS-3 layouts is structurally limited.** The
     working AltiVec R_LerpVerts wins (or breaks even) because output
     is vec4_t stride. Anywhere the output stride is 3 (lightmaps,
     vec3_t arrays), the AltiVec setup cost dominates because the
     final store is necessarily scalar-extracts.
  2. **The sister project's "neutral on QS, slight regression on
     attempt" pattern transfers cleanly to Q2.** Don't re-attempt this
     specific function shape. To make AltiVec lightmaps win, the
     STORAGE LAYOUT would need to change (s_blocklights → vec4_t
     stride with one wasted lane), which cascades into the downstream
     store loop at r_light.c:611-682 and would need to be carried
     all the way through `qglTexImage2D`'s GL_RGBA expectations.
  3. **Sawtooth dlight unlock requires a fundamentally different
     approach** — not SIMD on the existing code. Options for a
     future round: (a) per-light subrect upload only (smaller GPU
     transfer per dlight), (b) batch multiple lights into a single
     R_BuildLightMap pass, (c) accept gl_flashblend 1 as permanent.

Bench: 14.70 fps demo1 1024 vs 15.25 fps prior. The minus delta
within run-to-run noise but the signal is "no win" not "small win".

---

## 2026-05-23 — AltiVec R_LerpVerts produces warped alias-model geometry

What we tried: AltiVec port of `R_LerpVerts` (commit 55bfeb8). Each
vertex's `lerp = move + ov->v * backv + v->v * frontv` reduced to two
`vec_madd`s plus one `vec_st`, gated by `#ifdef __ALTIVEC__` so only
the G4 slice picked it up. Output array `s_lerped` is `static vec4_t
s_lerped[MAX_VERTS]` — naturally 16-byte aligned, so the 16-byte
`vec_st` should match.

What went wrong: monster alias models (md2 frame-lerped enemies +
weapon viewmodel) rendered with skewed/warped triangles on mini-g4
(G4 / Radeon 9200 / Tiger). World BSP geometry was unaffected
(R_LerpVerts only runs for alias models). User caught it visually —
the bench script's timedemo wall-clock advanced fine and even
reported +4.3% fps because the broken vertex math was strictly
cheaper than the correct math, so timedemo finished slightly faster.

The smoking-gun observation: a second mini-g4 bench at 1024×768 of
the SAME AltiVec binary that read 103.30 fps the first time read
17.50 fps on the retry. That's not noise — it's likely the GL driver
state from the warped-geometry render being corrupted into a slow
software-fallback path on the second pass.

Suspected root cause: `(vector float){a, b, c, d}` constant-init
syntax with `(float)byte` per-lane conversions. gcc-4.0 (the PPC
cross-compiler) does compile this syntax, but the lane-insertion
codegen for "expand 3 byte loads + 3 sint→float + 3 vector-inserts +
1 literal 0" can go wrong if the compiler uses a stack temp that
isn't 16-byte aligned, or generates a `vec_ld` with a wrong shift
permute.

Fix: reverted to the scalar implementation. The bench number gain
was real but conditional on broken vertex output, so it doesn't
count.

What we learned:
1. **Bench correctness is not visual correctness.** A timedemo can
   advance frames quickly while rendering garbage. Always corroborate
   a +N% AltiVec win with a screenshot diff against the scalar
   reference, especially when the change is in a per-vertex or
   per-luxel pipeline. The QuakeSpasm sister project's `r_brush.c`
   added an `-altivec-lm` opt-in default-off precisely because the
   initial smoke regressed; that's the inverse failure mode (visible
   regression, no correctness break) but it points to the same
   discipline.
2. **`(vector float){a, b, c, d}` with non-constant lane values is
   risky on gcc-4.0 PPC.** Prefer the safer pattern: write to a
   `float v[4] __attribute__((aligned(16)))` stack buffer, then
   `vec_ld(0, v)`. Slightly more code, much more predictable codegen.
3. Re-attempting AltiVec on R_LerpVerts requires the aligned-stack-
   load pattern + a visual A/B (screenshot of a monster from a fixed
   camera angle on yosemite scalar build vs mini-g4 AltiVec build).
4. The bench-only signal that something was wrong was the 103.30 →
   17.50 fps drop on the second run — keep an eye on bench-to-bench
   stability of the AltiVec slice; rapidly-degrading fps over runs
   suggests the GPU driver is being put in a degraded mode by bad
   geometry.

Bench delta on revert: see commit immediately after this entry.

---

## 2026-05-21 — `R_ApplyGLBuffer` toggling multitex destroys the GL_COMBINE_EXT setup

What we tried: the initial port of yquake2-latest's `gl1_buffer.c` into
`yquake2/src/refresh/r_buffer.c` followed the upstream pattern of
calling `R_EnableMultitexture(true)` on flush entry when the batch type
is `buf_mtex`, and `R_EnableMultitexture(false)` on flush exit. The
inner loop also called `R_TexEnv(GL_REPLACE)` on the second TMU as
part of multitex setup.

What went wrong: walls / floors / ceilings rendered flat yellow / beige
(with `gl_overbrightbits 4`) or flat grey-cyan (with OBB 2) on every
multitex platform — `mini-g4`, `quicksilver`, `mini-intel`. Took a
while to find because the initial diagnosis pointed at retex / driver
quirk / HD-texture-missing rather than at the buffer port. Manual user
inspection on `mini-g4` ruled out retex misses (textures were missing
even on areas the demo never tried to lookup-replace) and `gl_groupdraw
0` immediately fixed the visuals — narrowing it to the buffer flush
path.

Root cause: `R_DrawWorld` configures TMU1's TexEnv to
`GL_COMBINE_EXT` with `RGB_SCALE_EXT = gl_overbrightbits` BEFORE
`R_RecursiveWorldNode` walks the BSP. The buffer accumulates batches
across many surfaces, then flushes. Each flush was re-running
`R_EnableMultitexture(true)`, which calls `R_TexEnv(GL_REPLACE)` on
TMU1 — destroying the combiner state. The subsequent draw ran with TMU1
sampling lightmap-only, no colormap modulate. With `OBB4`'s `RGB_SCALE
4` baked into the combiner that the flush had just overwritten, the
output was lightmap × 1.0 (no scale) instead of (colormap × lightmap)
× 4 — looked like flat lightmap shading on a uniform colour.

Fix (commit `78c26f2`): the buffer flush MUST trust the outer code to
own the multitex enable lifecycle. Removed the
`R_EnableMultitexture(true)/false)` calls from `R_ApplyGLBuffer`;
replaced with a load-bearing comment block (`r_buffer.c:113-123` and
`r_buffer.c:186-192`) explaining why these toggles are forbidden.
`R_DrawWorld` (and `R_DrawInlineBModel`) enable mtex once for the whole
BSP walk + drain, and disable it after; the buffer is just a batching
layer that bind/draws without re-configuring TexEnv.

What we learned: **fixed-function GL TexEnv state is a global the
buffer cannot afford to touch**. The upstream `gl1_buffer.c` came from
a yquake2-latest tree that had already refactored `R_DrawWorld` to NOT
pre-configure TMU1 — the port worked there because the outer code did
no setup. In our 5.11 base the outer code DOES set up the combiner,
so the buffer's "helpful" re-toggle was actively destructive. Any
future port from yquake2-latest must check whether the inner state-
configuration was hoisted out into the buffer, or whether it stayed
in `R_DrawWorld`.

Bench: see commits `78c26f2` + `9527595` for the post-fix grid.

---

## 2026-05-19 — `gl_dynamic 1` on GeForce2 MX (sawtooth) is a catastrophic regression

What we tried: as part of the "sawtooth visual unlock" round (the box has
50-60% fps headroom over the 60 fps playability floor), flipped the
autoexec from `gl_dynamic 0` to `gl_dynamic 1` along with several other
visual unlocks (`gl_picmip 0`, `gl_skymip 0`, `gl_round_down 0`,
`gl_texturemode GL_LINEAR_MIPMAP_LINEAR`, `gl_shadows 1`).

What went wrong: 83 fps → 15 fps demo1 1024×768. 95 fps → 15 fps at 640.
~80% regression — well below the 60 fps floor. Reverted to `gl_dynamic 0`
and the other changes were retained; FPS settled at 70/78 (~15-18% under
baseline, still comfortably above the floor).

What we learned: the **GeForce2 MX cannot afford per-frame lightmap
rebuild for dlight-touched surfaces**, regardless of fps headroom in
other dimensions. The chip's fixed-function lightmap-reblend path is
prohibitive: a single rocket light or muzzle flash forces a `glTexSubImage2D`
upload + a re-blend pass per affected surface, and demo1 has enough
dlights to stay in that path most of the frame. Cost is bandwidth on the
AGP bus, not fillrate. The original autoexec comment ("GeForce2 MX still
pays the lightmap-reblend cost; skip") was load-bearing. Don't try
`gl_dynamic 1` on sawtooth again without a fundamentally different
dlight code path (e.g. a subrect upload that uploads only the touched
columns — would help here even though it didn't help G3 where dlights
are already off).

Bench data: see commit immediately following this entry.

---

## 2026-05-19 — Lightmap subrect doesn't unlock dlights on sawtooth either (try-2)

What we tried: after landing the lightmap subrect upload (Phase B #1, commit
937a870), retried `gl_dynamic 1` on sawtooth — the QS subrect commit
predicted ~4-12% wins on AGP-bound dynamic uploads, and the GF2 MX is one
of those candidate cards. Theory: less data per `glTexSubImage2D` =
breathing room on the 1999 AGP bus.

What went wrong: 15.25 fps demo1 1024×768. AND 15.3 fps demo1 640×480 —
identical at half the pixel count, which is the smoking gun: the
bottleneck is NOT GPU/AGP. The cost is CPU-side `R_BuildLightMap` +
`R_AddDynamicLights` per-luxel float math, which runs once per
dlight-touched surface per frame regardless of resolution. The subrect
optimization helps the GPU TRANSFER, not the CPU REBUILD. Wrong knob.

What we learned: when a regression scales the same at different
resolutions, it is CPU-bound, full stop. A bandwidth optimization can't
fix CPU. The actionable fix for `gl_dynamic 1` on a 500 MHz G4 is one
of: (a) AltiVec the `R_BuildLightMap` scaled-add inner loop + the
`R_AddDynamicLights` per-luxel branch; (b) ship `gl_flashblend 1`
instead (billboard halos, no per-surface relight at all).

Bench: 937a870_sawtooth_demo1_1024x768_run{1,2,3}.log + the 640x480
single-run probe. See results.csv row dated 2026-05-19T19:27:35Z.

Resolution: sawtooth ships with `gl_flashblend 1` (try-3, billboard
halos visible at ~69 fps demo1 1024) — the cheap-visual path that
maintains 60+ fps floor while still showing dlight presence.

---

## 2026-05-19 — Lightmap subrect upload port is gated to the wrong machine

What we tried (or rather, was on the candidate list): port QS commit
294b8d03's `gl_lightmap_subrect` from `~/quakespasm/Quake/r_brush.c` to
yquake2 5.11's `src/refresh/r_lightmap.c:71`. QS audit predicted +4.2% on
demo1 1024 — enough to lift yosemite over the 20 fps floor.

What went wrong (before any code change): the QS audit overlooked that
yosemite's autoexec sets `gl_dynamic 0`, which gates the entire
`R_RenderLightmappedPoly` dynamic path in 5.11 (`r_surf.c:279/429/651`).
With dlights off, `LM_UploadBlock(true)` never fires — the subrect
optimization has nothing to optimize on yosemite.

What we learned: **per-machine autoexec settings change which code paths
are hot.** Phase B cherry-pick priorities derived from QS bench data
need to be re-checked against the corresponding Q2 autoexec before
deciding which machines benefit. The subrect upload IS still on the
table for the gl_dynamic=1 cohort (quicksilver / mini-g4 / mini-intel /
imac-2019) — and per the dlight regression above on sawtooth, it might
even unlock dlights on sawtooth.

---

*(older entries below)*


