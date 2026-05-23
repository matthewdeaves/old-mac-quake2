# Next round — fresh plan after the texenv-fix session

Written 2026-05-23 after a fresh code review of `yquake2/src/refresh/`
+ inventory pass over `reference/yquake2-latest/` and
`reference/kmquake2/`. Supersedes the 2026-05-19 plan (most of which
landed: stb_image, group-draw, OBB4, AF, GL_FOG, waterwarp, subrect
upload, HD-pak bundle path, yosemite ULTIMATE config).

## Where we are

Live fps grid (median demo1, commit `e8ae174`+):

| Machine | 640×480 | 1024×768 | Floor | Margin | Bottleneck |
|---|---:|---:|---:|---:|---|
| imac-2019 | 711.75 | 726.40 | 60 | +666 | none — GPU never bound on GL1 |
| mini-g4 | 123.80 | 98.45 | 60 | +38 | CPU mixed |
| mini-intel | 59.40 \* | 101.20 | 60 | +41 (1024) | Quartz vsync + CPU |
| quicksilver | 72.40 | 72.35 | 60 | +12 | CPU |
| sawtooth | 78.20 | 67.35 | 60 | +7 | **CPU — R_BuildLightMap** (gl_flashblend mitigation) |
| yosemite | 45.15 | 25.10 | 20 | +5 | **GPU — Rage 128 fillrate** (ULTIMATE config) |

The two tight cells are **sawtooth 1024 (+7)** and **yosemite 1024
(+5)**. Everything else has headroom. So the question this plan
answers is: **what work do we do next, given that the bottlenecks
on the two pinned machines are completely different in nature?**

## What the code review found

Three angles audited (see appendix for the agent reports):

### Hot paths still unvectorized

- `r_light.c:540-599` **R_BuildLightMap inner scaled-add** — per-luxel
  byte→float scaled-add, runs every frame for every dynamically-relit
  surface. CPU-bound (regression is identical at 640 vs 1024 — see the
  2026-05-19 mistake-log entry on sawtooth). This is the single
  reason `gl_dynamic 1` is forbidden on sawtooth. **Top SIMD target.**
- `r_light.c:413-461` **R_AddDynamicLights per-luxel branch** — most
  luxels fail `fdist < fminlight`; per-row culling could skip whole
  rows when the bounding box doesn't intersect. Followed by SIMD on
  the surviving rows.
- `r_mesh.c:49-82` **R_LerpVerts** — per-vertex alias model frame
  lerp. `s_lerped` is already vec4_t-stride (16-byte aligned),
  AltiVec-ready out of the box. Hot when many alias models visible.
- `r_light.c:611-682` **R_BuildLightMap store-loop** — per-luxel
  `Q_ftol` + max-clamp + rescale + byte-pack. Branchy. SSE2-friendly
  on x86.
- `r_surf.c:113-122` **R_DrawGLPoly QGL function-pointer indirection**
  in the per-vertex immediate-mode loop (R128 path, with
  `gl_groupdraw 0`). Inline the function pointer to a local before
  the inner loop.

### Visual features still unported

Verified what's actually in the reference repos:

| Feature | Source | LOC | GPU req | Game.so? | Status |
|---|---|---:|---|---|---|
| **`gl_minlight`** (clamp dark luxels) | yquake2-latest gl1_main.c | ~30 | — | no | unported |
| **`gl_particle_square`** | yquake2-latest gl1_main.c | ~30 | — | no | unported |
| **`r_skydistance`** | KMQuake2 r_main.c:191 + r_sky.c | ~20 | — | no | unported |
| **`r_2D_unfiltered`** (sharp HUD under trilinear) | yquake2-latest | ~40 | — | no | unported |
| **KMQuake2 true alias stencil shadows** | r_alias_misc.c:148-160 + r_alias.c:729-790 | ~150 | stencil (have) | no | **half-wired** — see below |
| **KMQuake2 decals** (`r_fragment.c`) | r_fragment.c + client wire | ~500 | — | no — engine client/, not game | unported |
| **KMQuake2 `r_caustics`** (underwater caustic projection) | r_surface.c:368+1248,1806 | ~50 | multitex (have) | no | unported |
| **KMQuake2 `r_glows`** (shell/quad glow pass) | r_surface.c:870,1324 | ~80 | blend | no | unported |
| **KMQuake2 bloom** | r_bloom.c + r_arb_program.c | ~700 | ARB_fragment_program | no | quicksilver+imac only |
| **KMQuake2 rich particles** | r_particle.c + cl_particle.c | ~1500 | — | no (engine client) | unported, **risky** |

**Half-wired note on stencil shadows**: our fork ALREADY registers
`gl_stencilshadow` (r_main.c:1078) and the cvar gates a stencil
enable/disable around the existing flat-ground `R_DrawAliasShadow`
(r_mesh.c:332-381) — but this is just anti-overdraw, not volumetric.
The shadow is still projected to a single Z plane (`height = -lheight
+ 0.1f`), so it doesn't fall on walls. The KMQuake2 port replaces
the whole `R_DrawAliasShadow` with a shadow-volume approach
(`r_alias_misc.c:148-160`). The cvar plumbing is reusable; the inner
function body is the work.

### Bugs / smells found

- **`r_main.c:441` vs `header/local.h:453`** — `R_DrawParticles2`
  declared with `colortable[768]`, defined with `colortable[256]`.
  Harmless at runtime (C decays array params to pointers) but a real
  clang `-Warray-parameter` warning. Caller uses `[p->color]` where
  `p->color` is a byte, so `[256]` is correct → fix the header.
- **`r_light.c:243`** — cppcheck `identicalConditionAfterEarlyExit`,
  `(back<0)==side` checked twice. Worth a read.
- **`r_misc.c:141`** — screenshot path does pointer arithmetic on
  possibly-NULL `malloc` return. Theoretical crash; bench machines
  never OOM. Low priority.
- **`r_surf.c:896` `unsigned temp[128*128]`** = 64 KB stack alloc
  per dynamic surface per frame. Surface extents max out at ~34×34
  luxels (cf. `R_RenderBrushPoly`'s 34*34 buffer at r_surf.c:624).
  Wasted stack. Trivial fix.
- **`r_mesh.c:75-81`** — non-shell `R_LerpVerts` branch writes
  `lerp[0..2]` but `s_lerped` is vec4_t; the 4th lane stays from
  previous frame. Discarded downstream, so not a real bug — but a
  read-of-uninit that MSan would flag. Fix is `lerp[3] = 0` in the
  branch. Free.

### Static-analysis tooling — currently zero

Makefile is `-O2 -fno-strict-aliasing -fomit-frame-pointer -Wall
-pipe -g -MMD`. Just `-Wall`. **No** `-Wextra`, `-Wshadow`,
`-Wundef`, `-Wpointer-arith`, `-Wstrict-prototypes`,
`-Wmissing-prototypes`. The Ubuntu workstation has cppcheck 2.17,
clang-tidy / scan-build (LLVM 20), gcc-15 with `-fanalyzer`,
flawfinder.

cppcheck on `yquake2/src/refresh/` reports 1 error + 17 warnings +
250 style + 2 portability. Most "style" hits are `staticFunction`
hygiene (file-local funcs missing `static`). The 17 warnings are
mostly worth a look.

clang with `-Wextra -Wshadow -Wundef` flagged the prototype mismatch
above + `r_light.c:501` sign-compare + an `r_mesh.c:180` shadow.

---

## The plan

Six tiers ordered by **(visible-win × confidence) / risk**. Each
tier is its own session — none requires the previous to land first
unless explicitly noted.

---

### Tier 0 — instrument before optimizing (1-2h, do this FIRST)

#### 0.1 Add `scripts/analyze.sh` running cppcheck + clang -Wextra

Drop into `scripts/`, wire as a `make analyze`-equivalent. Concrete
target — appendix at bottom of this file has the snippet from the
static-analysis audit. Goal: surface real warnings before each Phase
B/C cherry-pick. Filter out `stb_image.h` + `staticFunction` noise
so the signal-to-noise is readable.

#### 0.2 Fix the cleanly-visible warnings

- `header/local.h:453` — change `colortable[768]` → `colortable[256]`
  to match the defn.
- `r_surf.c:896` — `unsigned temp[128*128]` → `unsigned temp[34*34]`
  to match `R_RenderBrushPoly` at line 624.
- `r_mesh.c:75-81` — zero `lerp[3]` in the non-shell branch.

These are all zero-risk cleanup. Land as one commit `chore: fix
warnings surfaced by clang -Wextra + cppcheck`. Bench grid as a
safety net but no behaviour change expected.

#### 0.3 Tighten the Makefile warning floor

Add `-Wshadow -Wpointer-arith -Wstrict-prototypes`. Leave `-Wextra`
off for now — it floods on the `unused-parameter` Win32 leftovers,
and we can't `(void)` those without churning unrelated files. Run a
fresh build on all three slices (g3 / g4 / lion) and silence any new
warnings before commit.

---

### Tier 1 — AltiVec the lightmap hot path (the sawtooth unlock)

This is the work that the 2026-05-19 mistake log explicitly flagged
as the actionable fix for `gl_dynamic 1` on sawtooth. Same code path
helps quicksilver + mini-g4 too, but sawtooth is the cell where it
moves the floor.

#### 1.1 `R_BuildLightMap` scaled-add AltiVec (~4h)

**Target:** `r_light.c:540-599`. Two scalar variants of byte→float
scaled-add, gated by `#ifdef __ALTIVEC__` so only the G4 slice
picks them up.

Pseudocode:
```c
vector float vscale = vec_splat(... pack scale[0,1,2,0] ...);
for (i = 0; i < size; i += 4) {
    vector unsigned char raw = vec_ld(0, &lightmap[i*3]);  /* 12 bytes */
    // permute 12-byte RGBRGBRGBRGB into 16-byte stride, expand to float,
    // vec_madd into vec_ld(s_blocklights[i]), vec_st back.
}
// scalar tail for size%4
```

Validate visually identical lightmaps on quicksilver (where dlights
are on) — diff one frame's `s_blocklights` against the scalar
reference. Bench sawtooth with `gl_dynamic 1` flipped back ON in the
autoexec — that's the success criterion. If the floor holds, **the
sawtooth visual unlock that's blocked since 2026-05-19 ships in the
same commit**.

#### 1.2 `R_AddDynamicLights` row-cull + AltiVec (~3h)

**Target:** `r_light.c:413-461`. Add the row-precheck: if
`td_at_row_start >= fminlight + (smax-1)²`, skip the row's inner
loop entirely. Then SIMD the surviving rows.

Most luxels in a dlight-touched surface fail the cutoff test; this
cuts iterations long before any per-luxel work. Combined with 1.1
this is the second half of the "unlock dlights on sawtooth" story.

#### 1.3 `R_LerpVerts` AltiVec (~3h)

**Target:** `r_mesh.c:49-82`. Already vec4_t-aligned output. Two MADs
per vertex on the G4 slice. Helps any G4 with many alias models
visible (demo1 boss room is the worst case).

#### 1.4 (optional, only if mini-intel is bottlenecked after Tier 2)
`R_BuildLightMap` store-loop SSE2 (~3h). Defer until we see whether
the mini-intel margin shrinks below ~20 fps from Tier 2/3 visual
additions.

**Bench gate for Tier 1:** sawtooth must end the round with
`gl_dynamic 1 + gl_flashblend 0` ≥ 60 fps demo1 1024. If we can't
land that, revert to `gl_flashblend 1` and keep only the speedups
that don't regress.

---

### Tier 2 — cheap visual wins (no GPU dep, 1-2h each)

These are all small ports that work on every machine and the
risk/effort is bounded enough to batch into one commit each.

#### 2.1 `gl_minlight` (yquake2-latest, ~30 LOC)

Clamp lightmap luxel minimum to N. Per-machine defaults: yosemite +
sawtooth 0 (no change), others 8-16. Stops pitch-black corners
without hurting fps. Trivial port.

#### 2.2 `gl_particle_square` (yquake2-latest, ~30 LOC)

Square particles via single `GL_POINTS` draw, no point-sprite ext
required. Helps yosemite specifically — R128 has buggy point-sprite
ext (currently OFF in autoexec) and falls through to
`R_DrawParticles2` (3 triangles per particle). Square path is one
draw call total.

#### 2.3 `r_skydistance` (KMQuake2, ~20 LOC)

Variable sky range cvar — fixes sky-clipping seam on large open
maps. Default 10000 matches KM. No fps cost. Trivial.

#### 2.4 `r_2D_unfiltered` (yquake2-latest, ~40 LOC)

Forces HUD glyphs through GL_NEAREST even when the texture mode is
GL_LINEAR_MIPMAP_LINEAR (yosemite ULTIMATE, sawtooth visual unlock).
Currently HUD numbers go fuzzy under trilinear. Cheap quality fix.

**Batch 2.1-2.4 into one commit each (or one combined cherry-pick
commit if they don't interact).** Bench grid for regression only —
no item is expected to move fps measurably.

---

### Tier 3 — replace the stencil-shadow stub with KMQuake2's volumetric port (~4-5h)

The cvar is already wired, the stencil setup is already correct, the
fleet all has 8-bit stencil. What's missing is the actual
shadow-volume math from `reference/kmquake2/renderer/r_alias_misc.c:148-160`
+ `r_alias.c:729-790`. Replace `R_DrawAliasShadow` body.

**Per-machine defaults:**
- yosemite: SKIP — R128 stencil on Panther 10.3.9 is untrusted +
  fillrate already tight at 25 fps.
- sawtooth: ON only after Tier 1 lands (need the BuildLightMap fps
  margin first).
- quicksilver / mini-g4 / mini-intel / imac-2019: ON.

**Risk: medium.** Stencil-volume rendering can ghost / flicker on
the first port. Bench-grid gate: no machine drops more than 5%, no
visual corruption on alias models (test in the start-of-level Quake
Guard chamber for predictable enemies).

---

### Tier 4 — KMQuake2 decals (the biggest visual lift, ~6h)

`reference/kmquake2/renderer/r_fragment.c` (327 LOC) + the client
wire (`R_MarkFragments` ref export → `V_AddDecal` in our `client/`,
NOT `baseq2/game.so`). The decals subsystem is engine-side, not
game-mod-side, so we don't touch the game DLL.

**Compatibility with `r_buffer.c`**: decals emit standard textured
triangles via array pointers — `r_fragment.c` has zero `qglBegin` calls
(verified). They flush during the alias / transparent pass, not the
world pass, so they don't break `gl_groupdraw`'s batch boundaries.

**Per-machine `r_decal_max`:**
- yosemite: 8 (fillrate)
- sawtooth: 16
- quicksilver / mini-g4 / mini-intel: 32
- imac-2019: 128

**Risk: medium.** Decal lifetime management + the `R_MarkFragments`
BSP-clipping function are their own subsystem. Need careful
integration with our BSP. Bench grid mandatory.

---

### Tier 5 — additional visual cherry-picks, opportunistic

#### 5.1 KMQuake2 `r_glows` (~80 LOC, ~3h)

Adds a second-pass modulate for shell / quad-damage / pent skins —
glowing creature outlines. Multitex-free fallback exists in KM's
code (multitex preferred). Cheap. Works on all 6 machines.

#### 5.2 KMQuake2 `r_caustics` (~50 LOC, ~2h)

Underwater caustic-light projection on submerged surfaces.
Multitex-required (have it on the four lower-multitex boxes).
Visual richness when underwater. Cheap once `r_caustics` cvar is
wired in surface.c the way KM does.

#### 5.3 Alpha-test + lightmap (~3h) and Transparent + lightmap (~2h)

KM's `r_trans_lighting` family in r_surface.c around 943-948. Cutout
textures (grates, vegetation) and glass currently render
unlightmapped → "floating" look. KM merges them back into the
lightmap path. Visual correctness, free on multitex boxes, one
extra pass on R128/GF2 MX (small fps hit on yosemite — likely
gate-off there).

---

### Tier 6 — defer indefinitely

- **Bloom (`r_bloom.c` + `r_arb_program.c`, 700 LOC)** — requires
  `GL_ARB_fragment_program`. R128 / GF2 MX / GMA 950 / R9200 don't
  have it. R9000 Pro on quicksilver does + imac-2019 does. Two
  machines is not enough to justify a 700-LOC port that won't
  unify the visual stack across the fleet. Park.
- **KMQuake2 `r_particle.c` rewrite (1500 LOC, client + renderer)** —
  too much surface area, touches client/cl_particle.c heavily.
  Risk of breaking demo playback. Park unless we hit a "particles
  are the bottleneck on the visual lift" wall.
- **MSAA via `SDL_GL_MULTISAMPLE`** — would need a vid_restart hook
  to apply on first boot, since the cvar isn't read until after
  SDL_SetVideoMode. Worth ~3h on imac-2019 only. Park behind decals.
- **GL1 gamma correction (yquake2-latest)** — `SDL_SetGamma` works
  fine on every machine we ship; the latest's software gamma is a
  fallback for systems where SDL gamma fails. Not a real problem
  for us. Park.
- **gl_farsee 1 on imac-2019** — CVAR_LATCH, needs the same
  vid_restart hook. Imac is at 700 fps; we don't need the win.
  Park.

---

## Suggested execution order

1. **Session A (~3h)**: Tier 0 — static analysis script + warning
   fixes + Makefile floor. Lands one cleanup commit, no behaviour
   change.
2. **Session B (~5h)**: Tier 1.1 + 1.2 — R_BuildLightMap +
   R_AddDynamicLights AltiVec. Goal: flip sawtooth `gl_dynamic 1`
   in the same commit. **The headline win of the round.**
3. **Session C (~3h)**: Tier 1.3 — R_LerpVerts AltiVec. Lands the
   second AltiVec hot path. Marginal on its own but completes the
   "G4 SIMD" story.
4. **Session D (~2h)**: Tier 2.1-2.4 — batch the cheap visual
   cherry-picks into one or two commits.
5. **Session E (~5h)**: Tier 3 — volumetric stencil shadows on
   capable boxes.
6. **Session F (~6h)**: Tier 4 — decals.
7. **Session G (~4h)**: Tier 5.1 + 5.2 — glows + caustics.
8. **Session H (~5h)**: Tier 5.3 — alpha-test + transparent
   lightmapped surfaces.

Total ~33h. Each session is independently shippable.

## Bench cadence per item (unchanged)

1. Code change → smoke bench on dirty tree (one machine, one
   resolution, 3 runs).
2. If no regression → `bench-and-commit.sh "Round X" --quick` lands
   the commit + bench row + raw logs.
3. Full 6-machine × 2 demos × 2 res × 3 runs grid at end of round.
4. Update `PPC_PLAN.md` live feature inventory with new commit SHA.

## Risk gating (unchanged)

Block any commit if:
- Any cell drops >5% fps from previous round's row
- yosemite drops below 20 fps demo1 1024
- Any G4 box drops below 60 fps demo1 1024
- Visual regressions (corruption, missing surfaces, wrong colours)
  on any machine

## What this plan does NOT include and why

- **No new feature flags / cvars not gated to existing cvars**.
  Every per-machine decision still flows through
  `scripts/bundle/autoexec-<machine>.cfg`.
- **No game.so / baseq2 modifications**. Every feature in the plan
  lives in the engine (renderer + engine `client/`). Decals are
  engine-side in KM, not mod-side.
- **No SDL2 / yquake2 7.21 base bump**. Out of scope — would lose
  the Panther + Tiger targets.
- **No new build host**. mini-intel stays the cross-build box.

---

## Appendix A — static analysis Makefile snippet (drop-in)

```make
ANALYZE_SRC := src/refresh src/client src/common

analyze-cppcheck:
	cppcheck --enable=warning,performance,portability --quiet \
	  --suppress=missingIncludeSystem \
	  --suppress=*:src/refresh/files/stb_image.h \
	  --error-exitcode=0 $(ANALYZE_SRC)

analyze-clang:
	@for f in $$(find $(ANALYZE_SRC) -name '*.c'); do \
	  clang -fsyntax-only -Wall -Wextra -Wshadow -Wundef -Wpointer-arith \
	    -Wstrict-prototypes -Wmissing-prototypes \
	    -Isrc/client/refresh -Isrc $$f 2>&1; \
	done | grep -E 'warning|error' | sort -u

analyze: analyze-cppcheck analyze-clang
```

## Appendix B — verified bugs / smells punch list

| File:line | Issue | Severity | Effort |
|---|---|---|---|
| `header/local.h:453` vs `r_main.c:441` | `colortable[768]` vs `[256]` array-parameter mismatch | clang warning | 1 min |
| `r_surf.c:896` | `unsigned temp[128*128]` = 64KB stack, only ~34×34 used | wasteful stack | 2 min |
| `r_mesh.c:75-81` | `s_lerped[i][3]` read-of-uninit (silently discarded) | MSan-only | 1 min |
| `r_light.c:243` | `identicalConditionAfterEarlyExit` — `(back<0)==side` twice | possible logic bug | 15 min to read |
| `r_light.c:501` | int/unsigned sign-compare | clang warning | 5 min |
| `r_misc.c:141` | screenshot malloc may return NULL → pointer arith | crash on OOM | 10 min |
| `r_mesh.c:180` | local `float l` shadows outer | warning | 5 min |

All seven are appropriate for the Tier 0 cleanup commit.

## Appendix C — what's left in the PPC_PLAN.md backlog

(For continuity — nothing here is new since 2026-05-21.)
- Phase B GL1 cherry-picks: most landed; remaining are `gl1_minlight`
  (this plan §2.1), `gl1_particle_square` (§2.2), GL1 gamma
  (parked, §Tier 6).
- Phase C visual ports from KMQuake2: stencil-shadow volumetric
  (this plan §Tier 3), decals (§Tier 4), bloom (parked §Tier 6),
  rich particles (parked §Tier 6), alpha-test + transparent
  lightmapped surfaces (§Tier 5.3).

End of plan.
