# Next round — fresh plan after v2.0.0

Written 2026-05-24, post-v2.0.0 release. Supersedes the 2026-05-23 plan
(every tier 0/1/2/4 item landed: analyze.sh + warning fixes, AltiVec
R_LerpVerts + row-cull, all four cheap visual cvars, decals). The
2026-05-23 doc is preserved in git history at commit `e8ae174~`.

## Where we are

Live fps grid (median demo1, commit `e629080`, full demo1+demo2 grid):

| Machine | 640×480 | 1024×768 | Floor | Margin | Bottleneck |
|---|---:|---:|---:|---:|---|
| imac-2019 | 711.75 | 726.40 | 60 | +666 | GPU never bound on GL1 |
| mini-intel | 222.80 | 100.30 | 60 | +40 (1024) | CPU; vsync fix unlocked 640 |
| mini-g4 | 100.45 | 56.80 \** | 60 | thermal-affected | mixed CPU/GPU; cool ≈ 97 |
| sawtooth | 72.90 | 65.45 | 60 | +5 | **CPU — R_BuildLightMap** still blocks `gl_dynamic 1` |
| quicksilver | 70.70 | 68.60 | 60 | +8 (vsync) | LCD vsync cap, GPU headroom unused |
| yosemite | 46.20 | 25.20 | 20 | +5 | **GPU — Rage 128 fillrate** (ULTIMATE config) |

Two cells still pinned: **sawtooth 1024 (+5)** and **yosemite 1024 (+5)**.

## What's shipped since v1.0.0

Visual: world decals (4 types), GL_FOG, waterwarp, group-draw batching,
MSAA, GL_ARB_point_sprite particles, gl_minlight, r_skydistance,
gl_particle_square, r_2D_unfiltered, HD-pak via CFBundle.

Perf: AltiVec R_LerpVerts, AltiVec R_AddDynamicLights row-cull, stb_image
JPEG decode (drops libjpeg dep), R_DrawDecals fast-path early-return,
group-draw + texenv fix unlock.

Engine: vsync-default fix (mini-intel +275% at 640), multitex state-leak
fix (GMA 950 decals), R_FindImage NULL-deref fix, per-machine autoexec
dispatched via `sysctl hw.model` + CFBundle, run-from-anywhere validated.

## Tiers for the next round

Ordered by **(visible-win × confidence) / risk**. Each tier independent.

---

### Tier A — small SIMD wins from the QS sister (1-2h each)

The QuakeSpasm port at `~/quakespasm/` has two trivially-portable
PPC SIMD wins that Q2 hasn't taken. Bring them across.

#### A.1 frsqrte `Q_rsqrt_ppc` — drop-in from QS

**Source:** `~/quakespasm/Quake/mathlib.h:66-73`. Single PPC `frsqrte`
intrinsic wrapper around the standard `1/sqrtf(x)` use sites in
Q2's `q_shared.c`. Used in vector normalization (hot during alias
rendering + lighting).

Gain: ~5-15% on `VectorNormalize`-bound paths on PPC. Marginal headline
fps but real on alias-heavy scenes. Free on x86 (not compiled in).

#### A.2 AltiVec 16-bit sound mixer

**Source:** `~/quakespasm/Quake/snd_mix.c:559-612`. Aligned-paintbuffer
mixer with runtime opt-out. Q2's sound code is still scalar.

Gain: sound takes ~5% of frame time on G4. AltiVec brings it down to
~1-2%. Bench gate: no audible artifacts on the test fleet (clipping,
phase issues). The opt-out cvar is the safety net.

**Tasks:** #42, #43 (already in the list).

---

### Tier B — KMQuake2 visual ports we deferred (3-5h each)

Three KM features that we passed on during the decals round, all
small and contained.

#### B.1 `r_glows` — shell / quad / pent creature outlines (~3h)

**Source:** `reference/kmquake2/renderer/r_surface.c:870,1324` (~80 LOC).
Adds a second-pass modulate for shell-skinned alias models — glowing
outlines around quad-damaged / invulnerable creatures. Multitex
preferred path, scalar fallback exists.

Visual: noticeable richness during combat, no fps cost on multitex
boxes (GMA 950 / R9000 / R9200). Mild cost on GF2 MX sawtooth
(single-TMU fallback path).

**Per-machine defaults:**
- yosemite: OFF (Rage 128 blend artifacts on overlapping passes)
- sawtooth: OFF initially, can flip ON after A/B bench
- quicksilver / mini-g4 / mini-intel / imac-2019: ON

**Risk: low.** Bounded change in alias render path. The cvar should
silently disable if `gl_state.shell` isn't supported.

**Task:** #19 (already in the list).

#### B.2 `r_caustics` — underwater caustic projection (~3-4h)

**Source:** `reference/kmquake2/renderer/r_surface.c:368+1248,1806`
(~50 LOC). Animated caustic-light texture projected onto submerged
surfaces. Multitex-required.

**Blocker** (carried from prior plan): KM uses `CL_PMpointcontents`
which isn't in stock yquake2 5.11. The fix is a 20-line `Cmod_BoxLeafnums`
+ `CM_BoxTrace` wrapper in `cmodel.c` — already done in yquake2-latest,
just need to lift the wrapper. Cleaner than the prior "blocked" status.

**Per-machine defaults:** ON for all multitex boxes (everything except
yosemite + sawtooth single-TMU path). Trivial GPU cost.

**Risk: low-medium.** The pmove wrapper needs careful testing — it's
called every frame for every underwater surface, must be O(log n) in
BSP depth, not a brute-force walk.

#### B.3 Alpha-test + transparent lightmapped surfaces (~4h)

**Source:** `reference/kmquake2/renderer/r_surface.c:943-948`
(`r_trans_lighting` family). Cutout textures (grates, vegetation) and
glass currently render unlightmapped → "floating" look. KM merges
them back into the lightmap path.

Visual: glass + grates look properly grounded in the world. Cheap on
multitex (one extra pass per transparent surface). Mild cost on
single-TMU yosemite — gate it off there.

**Risk: low.** Self-contained in r_surf.c.

---

### Tier C — quality-of-life polish (1-3h each, no behaviour change)

Small wins that aren't engine changes.

#### C.1 HD texture pack curation guide (~2h doc)

We have CFBundle HD-pak support (Resources/hd-pak/) but no docs telling
users how to populate it with community packs. The KMQuake2 community
has decent hi-res replacements for the wall/floor textures.

Deliverable: `docs/HD_PACK.md` extended with:
- Where to download community packs (q2pmp, Berserker, Knightmare)
- Layout (`hd-pak/baseq2/textures/<wad>/<tex>.tga`)
- Quality vs VRAM tradeoffs per GPU class
- Test demo to verify the pack loaded

#### C.2 OGG music replacement guide (~2h doc + 1 cfg knob)

Q2 retail shipped 11 tracks on CDDA. The `oggvorbis` rip is widely
available (Bandcamp, archive.org). yquake2 5.11 has OGG support
(`WITH_OGG`) which we currently disable. Enable conditionally on
machines with the libogg/libvorbis frameworks present (mini-intel +
imac-2019; PPC slices stay OFF — libvorbis-tremor is the alternative).

Deliverable: bench grid with OGG ON on Intel slices to validate no fps
regression + a `docs/MUSIC.md` install guide.

#### C.3 Per-machine FOV defaults (~30 min)

Modern monitors are widescreen but Q2 defaults to 90° horizontal FOV
(matching 4:3 era). On imac-2019's 5K display this looks pinched.
Wire `fov_default` per-machine in the autoexecs:
- yosemite (1024×768 4:3): 90 (no change)
- sawtooth/quicksilver/mini-g4 (CRT/LCD 4:3): 90
- mini-intel (1280×800 widescreen): 100
- imac-2019 (2560×1440 widescreen): 110

Cosmetic, zero risk. Validate visually that the HUD doesn't overflow.

#### C.4 Crosshair refresh (~1h)

The Q2 default crosshair sprites are basic. KMQuake2 ships richer
crosshair assets — bundle them as `Resources/hd-pak/pics/ch1.pcx`
… `ch7.pcx`. Per-machine default via `crosshair` cvar in autoexec.

#### C.5 Better Finder install nudge for HD pack (~1h)

The .app currently won't tell the user when an HD pack lives next to
`baseq2/` outside the bundle. Add a one-line console message at startup
if `baseq2/textures/` exists, listing how many overrides were detected.
Pure feedback, no behaviour change.

---

### Tier D — bigger investments (parked unless we want a v3.0.0)

#### D.1 KMQuake2 rich particles port (~10h, risky)

`r_particle.c` + `cl_particle.c` (1500 LOC), touches the demo
playback path. Visible win is large (better blood, sparks, smoke) but
risk of breaking demo1/demo2 timing is real. Bench grid would need
to validate frame count + timing not just fps.

#### D.2 KMQuake2 bloom (~8h, requires `GL_ARB_fragment_program`)

`r_bloom.c` + `r_arb_program.c` (700 LOC). Only quicksilver R9000 Pro
+ imac-2019 have the extension. Two-machine win for a 700-LOC port
that doesn't unify the visual stack. Park unless we want bloom
specifically on quicksilver.

#### D.3 Stencil-shadow volumetric (KMQuake2 alias_misc.c)

Tried last round on `gl_stencilshadow` — 60% fps regression on Tiger
ATI (R9000/R9200, see MISTAKES.md). Volumetric is more expensive than
the flat-plane stub. Only worth it on imac-2019 (Polaris handles it
free). Per-machine gate makes it a 5-line autoexec cvar change, not a
new feature. Park.

#### D.4 SDL2 / yquake2 7.21 base bump

Hard pass — loses Panther + Tiger targets. Out of scope.

---

## Suggested execution order

Three short sessions can land Tier A + B in a weekend:

1. **Session A (~3h)**: Tier A.1 + A.2 — QS SIMD backports. Two
   commits, no behaviour change beyond perf. Bench grid mandatory.
2. **Session B (~3h)**: Tier B.1 (`r_glows`) — visual win on combat
   shots, easy port. Multitex-only.
3. **Session C (~4h)**: Tier B.2 (`r_caustics`) — needs the
   `CL_PMpointcontents` wrapper first (~30 min), then the
   surface-projection port.
4. **Session D (~4h)**: Tier B.3 (`r_trans_lighting`) — cleanest of
   the three visual ports; glass + grates start looking grounded.
5. **Session E (~6h)**: Tier C — pure documentation + autoexec
   tweaks. One PR with HD pack guide, OGG guide, FOV defaults,
   crosshair pack, install nudge. Could be done in one session if
   the docs flow.

Total ~20h to v2.1.0 (Tier A+B+C combined).

A v3.0.0 would need Tier D — probably 25-40h of work and a real
risk of breaking existing rendering. Not on the immediate horizon.

## Bench cadence per item (unchanged)

1. Code change → smoke bench on one machine, one resolution, 3 runs.
2. If no regression → `scripts/bench-and-commit.sh "Round X" --quick`.
3. End-of-round: full 5-machine × demo1+demo2 × 1024+640 × 3 runs grid.
4. Update `PPC_PLAN.md` live inventory + README bench table.

## Risk gating (unchanged)

Block any commit if:
- Any cell drops >5% fps from previous round
- yosemite drops below 20 fps demo1 1024
- Any G4 box drops below 60 fps demo1 1024 (cool-machine baseline)
- Visual regressions on any machine

## What this plan does NOT include and why

- **No game.so / baseq2 mod changes** — all engine, all the time.
- **No new build host or toolchain** — mini-intel stays the cross-build box.
- **No SDL2 bump** — would lose Panther + Tiger targets.
- **No installer/.pkg** — keep `Quake2.app` drag-and-drop simple.

End of plan.
