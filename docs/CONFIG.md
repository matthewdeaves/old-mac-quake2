# Runtime config & toggleable knobs — yquake2 PPC port

How the self-contained per-machine config is assembled at launch, and the custom
cvars this fork adds. Read this when you touch `scripts/bundle/autoexec-*.cfg`,
`yquake2/src/common/misc.c` (`Q2_ExecConfigFromBundle`), or any `gl_*` default.

## Bundle is self-contained (CFBundle-loaded autoexec, THREE layers)

Autoexec cfgs ship INSIDE `Quake2.app/Contents/Resources/` and load in
THREE layers (mirrors the QuakeSpasm sister project — "best on known
machines, sane generic on everything else"):

- **Layer 0 — shared controls** (`autoexec-controls.cfg`): universal,
  machine-independent WASD + mouse-look scheme (parity with the
  QuakeSpasm fleet build). Execed FIRST so a later layer could override a
  key (none do). Overrides stock yquake2's ESDF layout.
- **Layer 1 — per-arch baseline** (`autoexec-ppc750/ppc7400/ppc970/
  x86_64.cfg`): selected at COMPILE time. dyld picks the fat slice that
  matches the host CPU, so the baseline baked into that slice is the one
  that runs. This is the floor that makes the game playable on ANY
  G3/G4/G5/Intel Mac, not just the bench boxes. Selection lives in
  `misc.c` via `#if Q2_ARCH_PPC970 / __VEC__ / __ppc__ / __x86_64__`.
  The `Q2_ARCH_PPC970` check MUST come first — the 970 slice also
  defines `__VEC__`, so without the explicit build macro it would fall
  into the ppc7400 branch.
- **Layer 2 — per-machine overlay** (`autoexec-<machine>.cfg`): selected
  at RUNTIME via `sysctlbyname("hw.model", ...)`, layered AFTER the
  baseline so it wins on the six known fleet boxes. Unknown models keep
  just the Layer-1 baseline.

All layers append to `Cbuf` in order (controls → baseline → overlay), so
each later layer's `set` lines override the earlier. See
`yquake2/src/common/misc.c:Q2_ExecConfigFromBundle` and the call site in
`Qcommon_Init`.

**Call-site placement is LOAD-BEARING — it is BEFORE `CL_Init()`/`VID_Init`
(right after `exec config.cfg`, before `Cbuf_AddEarlyCommands(true)`):**
- The cfgs use `set CVAR VALUE`, which CREATES the cvar on demand, so
  renderer cvars (`gl_picmip`, `gl_mode`, …) created here are picked up
  unchanged by ref_gl's `Cvar_Get` when it lazy-loads — identical to how
  the saved `config.cfg` (also execed before `CL_Init`) already reaches
  the first init. So there is NO need to wait for `ref_gl.so` to load.
- Crucially, the VIDEO-MODE cvars are set BEFORE `VID_Init` loads the
  renderer, so it comes up in the FINAL mode on the first frame with NO
  refresh-DLL reload. Applying them AFTER `CL_Init` (the old placement)
  triggered a reload on the first rendered frame that **hard-crashed the
  Rage128/Panther G3 on "start a new game"** (see MISTAKES.md 2026-05-31).
- `+set` from the cmdline (bench scripts) is an early command applied just
  after this block, so it still overrides the bundle config — keeping
  benches deterministic.

The cfgs use `set CVAR VALUE` syntax (not bare `CVAR VALUE`). This
matters because Q2's command parser only routes bare assignments
through `Cvar_Command`, which IGNORES unknown cvars — but `set` creates
the cvar if it doesn't yet exist, so renderer cvars that aren't
registered until `ref_gl.so` lazy-loads still take effect when the
DLL eventually pulls them in via `Cvar_Get` (which honours the
existing value).

**Cfgs ship COMMENT-STRIPPED.** `deploy.sh` + `make-dmg.sh` run
`sed 's,//.*,,' | grep -v '^$'` so the baseline + overlay stay small
(the repo files keep their docs). History: verbose comments once pushed the
combined config over the old fixed `cmd_text_buf` and caused a
`Cbuf_AddText: overflow` → garbled config → R300 wedge (buffer since bumped
8 KB→64 KB in `cmdparser.c`; see MISTAKES.md).

End-user install: drop `Quake2.app` + your own `baseq2/pak*.pak` next
to each other. The .app travels with all four per-arch baselines + all
six machines' per-machine overlays inside it — same .app runs on G3
Panther, G4 Tiger, G5 Leopard, Intel Lion, and modern Sequoia.

## Toggleable knobs (custom cvars this fork adds)

Same discipline as QuakeSpasm: every per-target visual / perf decision
must be flippable at runtime (cvar) or at launch (`-flag`). Custom cvars
this fork adds on top of stock yquake2 5.11:

| cvar | what | default per machine |
|---|---|---|
| `gl_fog` (+ mode/start/end/rgb) | cvar-driven GL_FOG | on (all) |
| `gl_waterwarp` | underwater frustum sine-warp | on (all) |
| `gl_decals` `gl_decal_max/life/fade` | KMQuake2 world decals | on; cap 8 (G3)→128 (imac) |
| `gl_msaa_samples` | MSAA (CVAR_LATCH) | 0 (PPC fixed-func)→8 (imac) |
| `gl_lightmap_subrect` | dirty-column dynamic LM upload | on (no-op if dlights off) |
| `gl_groupdraw` | batched `qglDrawElements` (+ CVA lock) | on G4+/x86, off G3 |
| `gl_minlight` `gl_skydistance` | lightmap floor / sky extent | per-machine |
| `gl_particle_square` `gl_pointsprites` `r_2D_unfiltered` | particle/HUD tweaks | per-machine |
| `gl_glows` | sphere-map energy shell glow | on multitex, off G3/sawtooth |
| `gl_trans_lighting` | lightmapped glass/grates (map-load latched) | on multitex, off G3/sawtooth |
| `gl_caustics` | water-surface caustic overlay | on multitex, off G3/sawtooth |

### Tweaking the caustic look (`gl_caustics`)

The overlay texture is generated procedurally — there is no asset to edit.
Tune it in `R_InitCausticTexture` (`yquake2/src/refresh/r_misc.c`) and rebuild:

- `caustic_waves[]` — integer `(a,b)` frequency pairs that are *summed*. More
  pairs / higher numbers → finer, busier, more irregular net. **Keep them
  integers** or the tile stops wrapping seamlessly. Mixed signs tilt ridges
  different ways (more organic).
- `CAUSTIC_POWER` — vein sharpness. ~2–3 = thin hard cords; ~1.3–1.6 = soft
  broad shimmer. Shipped "K" preset = **1.5**.
- `CAUSTIC_GAIN` — overall brightness 0..1. "K" = **0.55** (understated);
  raise toward 1.0 for a stronger effect.
- Scroll speed + the blue-ish tint live in `R_EmitWaterPolys` (`r_warp.c`):
  the `cscroll` rate, the per-tile texcoord scale (`1/64`), and the
  `qglColor4f(0.55,0.7,0.8,1)` tint.

Preview presets fast without a Mac build: `~/caustic_gallery/gen2.py` renders
candidates to PNG/HTML (open in **Chrome** — snap-Firefox can't read `/tmp` or
files outside `$HOME`). The product-vs-sum bug that caused the v2.2.6 circle
grid is written up in MISTAKES.md.
| `gl_zfix` | polygon-offset coplanar surfaces | on (all) |
| `gl_farsee` | extended far clip (CVAR_LATCH) | on x86 only |
| `gl_bloom` (+ alpha/darken/size) | fixed-function light bloom | **off — WIP, broken on GL1, see MISTAKES.md** |
| `vid_desktopfullscreen` | native-res same-mode fullscreen capture (no mode switch — the only R300/Leopard-safe fullscreen) | on iMac-class (ppc970 baseline + imac-g5); off elsewhere |

To A/B a single cvar against the production cfg without rebuild/redeploy, use
`+cmd "set X Y"` (a LATE command, runs after the bundle exec, so it overrides
cleanly). If the tweak wins, fold it into `scripts/bundle/autoexec-<machine>.cfg`,
redeploy, re-bench. See `docs/BENCH.md`.
