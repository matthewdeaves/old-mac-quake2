# Mistakes log: settled negatives, do not re-chase

Append-only register of things that were tried and were wrong, harmful or
misjudged. Each entry exists so a future round does not re-litigate it on
incomplete information. **Read this before lighting up an idea that smells
"easy / load-time only / zero risk"**, that smell test has failed here four
times, and three of those took a machine down.

Newest first. Where a mechanism became a standing decision it lives in
`docs/adr/` and the entry here is a pointer, not a copy.

Cross-applicable lessons from the sister project are in
`~/quakespasm/MISTAKES.md`, especially benchmark concurrency and SDL framework
dyld install-name quirks.

---

## Build: packaging and deploy

**2026-08-22, a staleness gate that caught the bug it was written for, and
refused every good build.** `build-fat.sh` fused an arm64 slice built three
hours before the source the other five came from, printed "fusing SIX" and
exited 0. The content-hash gate added to stop that was exercised only against a
reproduction of the stale slice, passed, and was shipped. It then refused a
completely current six-slice build, twice, for two unrelated reasons: the
staged arm64 directory never received a copy of its `SOURCE-STAMP`, and
`build-arm64.sh` computed its stamp while its own temporary Makefile edit was
still applied, so it recorded a tree state that the EXIT trap reverted moments
later and that never exists at rest. Commits `ea922696`, `0b526e06`,
`cabeae7e`; issue #17.

*The lesson is about testing, not about hashes: a check that REFUSES bad input
must be proved to PASS good input, and the passing direction is the one that
gets skipped.* A gate that blocks legitimate work does not fail loudly, it gets
switched off. Two corollaries worth keeping: a driver that mutates the source
tree in order to build must compute its stamp BEFORE the mutation, checked
against where the trap fires rather than where the write call sits; and a build
output directory living inside the source tree must be excluded from the hash,
or the hash of unchanged source moves depending on what was last built.

**2026-08-22, `strings` reported three of six slices as having no architecture
string at all.** Verifying that every slice of the fused `baseq2/game.so`
self-identifies, the PowerPC slices came back empty while `amd64`, `i386` and
`arm64` read correctly. Nothing was wrong with the binary. `strings` defaults to
a four-character minimum and `ppc` is three, so it needs `-n 3`. *A verification
tool returning nothing is not evidence that the property is absent.* This one is
specifically dangerous because it produces a false NEGATIVE in exactly the check
`docs/adr/0006` exists to make people run, and the reading looks plausible: the
three PowerPC slices are also the three that genuinely did report `unknown`
before the fix in `0647fbcb`.

**2026-07-25, `-faltivec` silently un-stamped the ppc7400 cpusubtype.** Nearly
shipped a fat no G3 could launch; caught before release. Root cause, blast
radius and the assert-and-re-stamp fix: **ADR 0001**. The general lesson: a
compiler flag added for one reason can quietly undo something unrelated three
layers down, and the only defence is asserting the property you actually care
about on the artifact itself.

**2026-05-31, chased a phantom "G3 corrupt renderer"; the real cause was my own
stale DMG mounts.** Root cause and the deploy-verify fix: **ADR 0006**. The
wrong theory is the point: I assumed flaky retro hardware (old disk, non-ECC RAM
corrupting the copy). **It was wrong**, the G3 has a near-new SSD and hashed
the file `060cc6dc…` three times deterministically in place, and a copy-to-disk
hashed clean. *Do not reach for "flaky retro hardware" before proving it: hash
the file in place and copy-test it first.* Second lesson: verify at the LAST hop
the user runs (the install directory), not an earlier one, and a failing deploy
that still prints a success-ish line is worse than one that errors.

**2026-05-31, DMG packaging flipped ONE byte and shipped an
illegal-instruction crash to every G4.** Root cause, opcodes and the three-part
fix: **ADR 0006**. `hdiutil verify` is not a content check. Do not run the
build or packaging on the flakiest hardware in the fleet when a healthier
machine does the same job.

**2026-05-31, config comments overflowed the fixed command buffer, garbled the
config, and wedged the R300 GPU on "new game" (shipped in v2.2.0).** Root cause
and the two-layer fix: **ADR 0007**. Lessons: shipped config text has a hard
size budget when the engine buffers it; a timedemo is not a substitute for
actually starting a new game; and when a change looks "harmless everywhere",
check the machine with the least forgiving driver, which turns soft failures
into hard ones.

## Testing build scripts

- **Stubbing the network does not make a build script safe to run.**
  `scripts/build.sh:247` is `rm -rf "$REPO_ROOT/build/q2-$TARGET"`, and it runs
  long before anything touches a mini. On 2026-08-22 a test run with `rsync` and
  `ssh` stubbed on `PATH` reached it and deleted a real `ppc7400` slice; the
  stubbed fetch then replaced nothing, leaving a `SOURCE-STAMP` with no binary
  beside it. `build/q2-fat` was already fused so nothing shipped wrong, but the
  intermediate had to be rebuilt. Run a build script against a COPIED tree with
  its own `REPO_ROOT`, never the live one. The copy costs nothing: `build.sh`
  only needs `scripts/` and a writable `build/`.

- **Backticks in a `git commit -m "..."` message RUN as commands.** On
  2026-08-22 a commit message here quoted the filing recipe it was replacing,
  inside backticks, inside a double-quoted `-m` string. The shell substituted it
  before git ever saw it, so `gh issue create --project Retro` was EXECUTED
  against this repo. Nothing was created only because `gh` refuses without
  `--title` and `--body` when non-interactive. The commit still pushed, with the
  quoted text silently deleted from the message, reading "It taught ,". Commit
  messages here routinely quote shell, so this is live, not theoretical. Write
  them with a quoted heredoc (`git commit -F - <<'MSG'`), which does not expand
  anything. Never `-m` with backticks in it.

- **`git add -A scripts/` swept another session's files into a commit about
  something else.** On 2026-08-22 old-mac-build-host synced both host pickers
  into this working copy with `sync-build-lock.sh --write` while a shellcheck
  triage was in progress here. `git add -A scripts .github` took all of it, so
  `d25f2b81` carries 122 lines of picker changes under a message that describes
  only shellcheck work, and it was pushed before anyone looked. The code was
  good and is verified below, but the record was wrong and pushed history cannot
  be rewritten. Nothing arbitrates working trees, only machines, so a sibling
  repo can write into yours at any moment. Stage by name, or read `git status`
  immediately before `git add`, and never use `-A` on a directory a sync
  targets.

- **A check that cannot read its input still prints a pass.** Three in one
  session on 2026-08-22, all confident-looking:
  `grep -rlE ... scripts | wc -l` reported `0` one-argument call sites while the
  directory was unreadable; `for spec in "a b c"` under zsh did not word-split,
  so six scripts were invoked under one garbage name and every case read
  "skipped"; and `git show ... 2>&1 | shasum` hashed the error text into a
  plausible `db132943...` when the real answer was `e3b0c442...`, sha256 of
  empty. Redirect stderr separately, assert the input is readable and non-empty,
  and prove a negative check still FIRES on a known-bad input before believing a
  clean run.

## Video init and the fullscreen path

**2026-05-31, per-machine config applied AFTER `CL_Init` triggered a
refresh-DLL reload that hard-crashed the Panther/Rage 128 G3 on "start a new
game".** Root cause and the fix: **ADR 0007**.

**2026-05-31, first-launch `vid_restart` to apply per-machine defaults early
(tried in v2.2.2, REVERTED).** The idea was to make the tuned fullscreen,
resolution and picmip apply on the first launch instead of the second. It worked
on G4, G5 and Intel and **hard-crashed the G3**:
`VID_CheckChanges → VID_LoadRefresh → QGL_Shutdown → Com_Error → VID_Shutdown →
R_Shutdown → GLimp_Shutdown → SDL_GL_SwapBuffers`, `EXC_BAD_ACCESS at 0x134`.
It is the same fatal reload, issued deliberately.

A compile-time guard was tried to exclude the bare-G3 slice:
`#if !(defined(__ppc__) && !defined(__VEC__) && !defined(Q2_ARCH_PPC970))`.
Verified that `gcc-4.0 -arch ppc -mcpu=750` defines only `__ppc__` /
`__POWERPC__` and not `__VEC__`, so the macro *should* have excluded it, **the
crash persisted identically.** The fix was to drop the `vid_restart` entirely;
the real fix came later by moving the config call site (ADR 0007).

Lessons: (a) `vid_restart` is not safe to issue automatically on the legacy
Panther/Rage 128 stack, treat it as interactive-menu-only there; (b) "tested
green on 4 of 5" is not "works", and the 5th, oldest, least forgiving box is
exactly where a video-init change bites; (c) when a fix needs a per-slice
compile guard to be safe, that is a signal the fix itself is wrong for this
fleet.

**2026-05-31, the iMac G5's R300/Leopard driver hard-hangs the whole OS on a
non-native fullscreen mode switch.** Hazard, mitigations and the
never-bypass rule: **ADR 0008**. The "load-time only / zero risk" smell test
failed here: a one-line resolution flag that is inert everywhere else can take a
whole machine down on one GPU + OS combination. When adding a box with a
new-to-the-fleet GPU/OS pair, assume the fullscreen path is the first thing that
will bite and validate it windowed or same-mode before triggering a remote mode
switch you cannot physically recover from.

**2026-05-31, `killall -KILL` on a fullscreen G5 leaves the screen BLACK.**
The R300 display capture is never released. Always TERM, sleep, then KILL:
**ADR 0008**.

## Renderer features

**2026-05-31, `gl_caustics` drew a grid of circles on water: brightness was a
PRODUCT of gratings, not a SUM (fixed v2.2.6).** The overlay tiled a grid of
soft round blobs across every water surface, on **both** the G5 (Radeon 9600 /
Leopard) and the G3 (Rage 128 / Panther).

*Why the both-GPUs fact mattered:* the first instinct, and an agent's first
theory, was a multitexture/TMU state leak from the new `gl_trans_lighting` path,
i.e. a driver-specific explanation. An identical artifact on two completely
different GPUs and drivers means a **deterministic logic bug in shared code**.
(Water is `SURF_DRAWTURB` and early-outs of the lightmap path, so trans-lighting
was never touching it.) *Same bug on different drivers ⇒ look for logic, not
driver state.*

*Root cause:* `R_InitCausticTexture` (`r_misc.c`) computed pixel brightness as
`a*b`, the **product** of two sine gratings, then cubed it. A product of two
gratings peaks at a regular lattice of isolated points; cubing sharpened each
peak into a round blob, giving a grid of circles. The comment claimed it made a
"net", but the maths made dots. Real caustics are connected veins, the
zero-crossing contour of a **sum** of waves.

*Fix:* brightness = `1 - |sum_of_sines| / N`, sharpened with a tunable `pow()`
and scaled by a gain. Parameterised as `caustic_waves[]` / `CAUSTIC_POWER` /
`CAUSTIC_GAIN`; shipped the soft "K" preset. All frequencies are integers so the
tile still wraps seamlessly. `r_decal.c` was never involved.

*Tooling note:* to preview candidate textures, snap-Firefox is sandboxed and
**cannot read `/tmp` or anything outside `$HOME`** ("can't find page"). Use
Chrome and stage previews under `$HOME`.

**2026-05-31, the `gl_trans_lighting` port missed a guard and `ERR_DROP`ed on
the first map with non-warp glass (base1), which presented as a freeze (fixed
v2.2.5).** A byte-verified DMG still froze "start a new game" on the G4-mini and
the iMac G5 (state `R`/`U`, pegged CPU, ignored SIGTERM) while the G3 was fine.
It looked like a fullscreen / R300 wedge. With `logfile 2` flushed the real
cause printed: `ERROR: R_BuildLightMap called for non-lit surface`
(`r_light.c`, `ERR_DROP`).

*Root cause:* at map load `r_model.c` calls `LM_CreateSurfaceLightmap` for
`SURF_TRANS33/66` surfaces when the cvar is on, which calls `R_BuildLightMap`,
but `R_BuildLightMap`'s **stock** guard rejects
`SURF_SKY|SURF_TRANS33|SURF_TRANS66|SURF_WARP` as "non-lit". kmquake2, the
feature's upstream, relaxes that exact line to `(SURF_SKY|SURF_WARP)`. We copied
the feature but not the guard change.

*Fix:* one line in `r_light.c`, matching kmquake2. Non-warp translucent surfaces
carry real BSP lightmap samples and are meant to be lit; with the cvar off they
never reach `R_BuildLightMap` anyway.

*Lessons:* (1) a "fullscreen crash" that leaves a live, pegged process with no
crash log is almost always an `ERR_DROP` to console, read the flushed log first
(ADR 0009). (2) The architecture split (G3 ok, G4+G5 fail) was a **red herring**:
it tracked which features the per-machine config enables, not the CPU. Bisect by
the actual variable, not the coincident one. (3) `+map base2` is not "new game"
, test the real first map (ADR 0009). (4) **When porting a feature, port the
whole diff, including the defensive guards it relaxes.**

**2026-05-29, fixed-function bloom: too slow on PPC, and `R_LoadPic` eats the
screen texture.** A fixed-function light bloom post-process (`r_bloom.c`,
`gl_bloom`): capture the back buffer with `glCopyTexSubImage2D`, downsample,
darken to isolate brights, separable blur, additive composite, hooked at the end
of `R_RenderView`.

1. **Prohibitively slow on a 2001 GPU.** quicksilver R9000 Pro: **66.95 → 25.50
   fps** demo1 1024, **-62%**, below even the relaxed ~40 fps G4 tolerance. The
   per-frame fullscreen copy plus multiple sample passes are fillrate murder on
   a 1999–2005 part.
2. **Visually broken on GMA 950 / Lion.** The first cut left the bloom workspace
   visible as a black box in the back-buffer corner plus a heavy additive wash.
   Adding a "restore the scene from the captured screen texture, then add bloom"
   blit fixed the corner in principle, but the whole 3D scene came back black,
   almost certainly because **`R_LoadPic(..., it_pic, ...)` resizes and repacks a
   large (1024²) pic texture**, so the `glCopyTexSubImage2D` capture region
   overflows the real texture and the copy silently stays empty (memset 0).

Shipped **disabled** (`gl_bloom 0` everywhere, binary default 0), code kept
in-tree as wired WIP. Lessons: (a) a fullscreen post-process is the wrong shape
for the PPC fillrate budget, it needs sub-resolution work and probably only
ever makes sense on the iMac; (b) **do not use `R_LoadPic` / `it_pic` for a
render target**, a redo needs a dedicated full-size texture created straight
via `qglTexImage2D` so `glCopyTexSubImage2D` has a matching destination.

**2026-05-29, procedural/effect textures get freed on map change unless
protected (latent).** `gl_glows` and `gl_caustics` build a procedural texture
once at `R_Init` and stash the `image_t*` in a global, like `r_particletexture`.
`R_FreeUnusedImages` runs on every map change and frees any image whose
`registration_sequence` is not current; the new textures were not in the protect
list, so they would be freed at the first map change and the feature paths would
then bind a deleted texnum. It did not surface in demo1 benches or screenshots
only because those frames barely exercise the shell and caustic paths, a real
"looked fine, was broken" trap. **Any texture created once at init and held in a
global must be added to the `R_FreeUnusedImages` protect block** (ADR 0012).

**2026-05-23, `gl_stencilshadow 1` on Tiger ATI drivers regressed 60% fps.**
mini-g4 (R9200, ATI Tiger driver), demo2 1024x768: **103.6 → 40.6 fps**. The
R9200's per-fragment `GL_INCR` stencil op runs on a very slow driver path and
the bench scene has many monsters. Reverted on all four slow-stencil machines;
blob shadows (`gl_shadows 1`) stayed on. **Lesson:** 8-bit stencil being
*requested* does not mean the per-fragment op path is fast, and the
`have_stencil` flag in `r_mesh.c` only checks that stencil bits were granted, so
it cannot guard for this.

**This decision was reversed on 2026-06-06 on figures that are now known to be
invalid**, they came from the `res=1` runs that rendered 1x1 pixels (ADR 0009).
Re-taking it is issue #7. See ADR 0010; do not quote the 2026-06-06 numbers.

**2026-06-06, the blob-shadow fallback the configs claimed was never actually
implemented, and the first attempt drew nothing.** `R_DrawAliasShadow`
(`r_mesh.c:427`) projects **every** model triangle flat onto the floor; the
stencil ops (`GL_EQUAL,1,2` + `GL_INCR`) are the only thing masking each floor
pixel to draw once. With `gl_stencilshadow 0` the projected leg/torso/arm
triangles overlap and each re-blends at α=0.5, compounding into dark blotches.
The first blob replacement used `GL_MODULATE` with a `(0,0,0,0.5)` vertex
colour, which **collapses to transparent black on the Tiger ATI driver**, so
there was literally no shadow. Fixed by switching to `GL_REPLACE` with the
50% alpha pre-baked into `shadow.tga`.

**2026-05-23, multitexture state leaks into ad-hoc draw passes on GMA 950.**
`R_DrawDecals` (`r_decal.c`) bound the decal texture to TMU0, called
`R_TexEnv(GL_MODULATE)` and drew alpha-blended quads. Correct on yosemite (Rage
128, no multitex) and mini-g4 (R9200); on mini-intel (GMA 950, Lion driver) the
same build rendered minigun decals as **light grey discs** instead of dark
bullet holes, shape, rotation, falloff and position all right, only the colour
wrong.

*Root cause:* `R_DrawWorld` leaves multitexture **enabled** with TMU1 holding
the lightmap and an overbright combiner state (`GL_RGB_SCALE_EXT 4` when
`gl_overbrightbits 4`). The R9200 and Rage 128 drivers apparently reset TMU1's
combine state when TMU0 binds a new texture; the GMA 950 Lion driver does not.
So `R_TexEnv(GL_MODULATE)` set TMU0's env while TMU1 kept applying the bright
lightmap, modulating the dark decal texel up to grey.

*Fix:* explicit `R_EnableMultitexture(false)` at the start of `R_DrawDecals`.
**Lesson:** GL state cleanup is the caller's responsibility. Any ad-hoc draw
pass that runs after `R_DrawWorld` must explicitly disable multitexture if it
expects single-texture semantics. "It works on PPC" is not a sufficient sanity
check for a state-machine bug.

**2026-05-21, `R_ApplyGLBuffer` toggling multitexture destroyed the
`GL_COMBINE_EXT` setup.** The initial port of yquake2-latest's `gl1_buffer.c`
followed upstream in calling `R_EnableMultitexture(true)` on flush entry and
`(false)` on exit. Walls, floors and ceilings then rendered flat yellow/beige
(with `gl_overbrightbits 4`) or flat grey-cyan (with OBB 2) on **every**
multitex platform. It took a while to find because the first diagnosis pointed
at retexturing, a driver quirk, or missing HD textures; `gl_groupdraw 0`
immediately fixing the visuals is what narrowed it to the buffer flush path.

*Root cause:* `R_DrawWorld` configures TMU1's TexEnv to `GL_COMBINE_EXT` with
`RGB_SCALE_EXT = gl_overbrightbits` **before** `R_RecursiveWorldNode` walks the
BSP. Each flush re-ran `R_EnableMultitexture(true)`, which calls
`R_TexEnv(GL_REPLACE)` on TMU1, destroying that combiner state. The draw then
ran with TMU1 sampling lightmap-only and no colormap modulate: output was
lightmap x 1.0 instead of (colormap x lightmap) x 4.

*Fix (commit `78c26f2`):* the buffer must trust the outer code to own the
multitexture enable lifecycle. The toggles were removed and replaced with a
load-bearing comment block (`r_buffer.c:113-123` and `:186-192`). `R_DrawWorld`
and `R_DrawInlineBModel` enable mtex once for the whole BSP walk and drain, and
disable it after.

**Lesson, and it generalises to every future cherry-pick:** fixed-function GL
TexEnv state is a global the buffer cannot afford to touch. Upstream's
`gl1_buffer.c` came from a tree that had already refactored `R_DrawWorld` to
**not** pre-configure TMU1, so the port worked there. In our 5.11 base the outer
code does set up the combiner. **Any future port from yquake2-latest must check
whether the inner state configuration was hoisted out into the new code or
stayed in `R_DrawWorld`.**

## Dynamic lights on the GeForce2 MX: three attempts, all negative

**2026-05-19 (try 1), `gl_dynamic 1` on sawtooth is catastrophic.**
**83 → 15 fps** demo1 1024x768, **95 → 15 fps** at 640, roughly **-80%**. The
GF2 MX cannot afford per-frame lightmap rebuild for dlight-touched surfaces
regardless of headroom elsewhere: a single rocket light or muzzle flash forces a
`glTexSubImage2D` upload plus a re-blend pass per affected surface, and demo1
has enough dlights to stay in that path most of the frame. The cost is AGP
bandwidth, not fillrate. The original autoexec comment ("GeForce2 MX still pays
the lightmap-reblend cost; skip") was load-bearing.

**2026-05-19 (try 2), the lightmap subrect upload does not unlock it either.**
After landing `gl_lightmap_subrect` (commit `937a870`), which predicted ~4-12%
on AGP-bound dynamic uploads: **15.25 fps** demo1 1024x768 **and 15.3 fps at
640x480**, identical at half the pixel count. That is the smoking gun: the
bottleneck is not GPU or AGP, it is CPU-side `R_BuildLightMap` +
`R_AddDynamicLights` per-luxel float maths, which runs once per dlight-touched
surface per frame regardless of resolution. **A bandwidth optimisation cannot
fix CPU.** When a regression scales the same at two resolutions, it is CPU-bound.

**2026-05-23 (try 3), AltiVec `R_BuildLightMap` is net-negative.** Ported the
`scale != 1.0F` paths (both the `nummaps==1` assign and `nummaps>1` accumulate
variants). The output stride is 3 floats, incompatible with `vec_st`'s 16-byte
aligned contract, so each loop body builds aligned stack temps for input and
accumulator, `vec_madd`s, `vec_st`s to a temp, then scalar-extracts lanes 0-2.

- mini-g4 demo1 1024 on the `gl_dynamic 1` path that actually exercises it:
  **101.25 → 98.95 fps (-2.3%)**.
- sawtooth at `gl_dynamic 1`: **14.70 fps**, slightly worse than the 15.25 from
  try 2.

*Root cause:* per-iteration setup overhead. The scalar-extract-after-`vec_st`
pattern trades one cheap parallel `vec_madd` for an extra `vec_ld` per input, an
extra `vec_st` to a stack temp per output, and three scalar loads from that
temp. Net per-luxel cost exceeds the scalar 3 fmul + 3 fmadd.

*Reverted*, including the `__attribute__((aligned(16)))` on `s_blocklights`;
sawtooth restored to `gl_dynamic 0` + `gl_flashblend 1` (~69 fps demo1 1024, the
shipped answer, billboard halos, no per-surface relight at all).

*Do not re-attempt this function shape.* **AltiVec on array-of-structures-3
layouts is structurally limited**: `R_LerpVerts` can win because its output is
`vec4_t` stride; anywhere the output stride is 3 (lightmaps, `vec3_t` arrays)
the setup cost dominates because the final store is necessarily scalar extracts.
Making it win would need the **storage layout** to change (`s_blocklights` to
`vec4_t` stride with one wasted lane), which cascades into the downstream store
loop at `r_light.c:611-682` and would have to be carried through
`qglTexImage2D`'s `GL_RGBA` expectations.

Options left for a future round, none of them SIMD on the existing code:
per-light subrect upload only; batching multiple lights into a single
`R_BuildLightMap` pass; or accepting `gl_flashblend 1` as permanent.

**2026-05-19, the subrect port was queued against the wrong machine.** Before
any code changed: the sister-project audit predicting +4.2% on demo1 1024 for
yosemite overlooked that yosemite's autoexec sets `gl_dynamic 0`, which gates
the entire dynamic path in 5.11 (`r_surf.c:279/429/651`). With dlights off
`LM_UploadBlock(true)` never fires and there is nothing to optimise. **Per-machine
autoexec settings change which code paths are hot**, re-check a cherry-pick's
justification against the target's own config first (ADR 0010).

## AltiVec

**2026-05-23, AltiVec `R_LerpVerts` produced warped alias-model geometry
(commit `55bfeb8`, reverted).** Each vertex's
`lerp = move + ov->v * backv + v->v * frontv` reduced to two `vec_madd`s plus
one `vec_st`, gated by `#ifdef __ALTIVEC__` so only the G4 slice picked it up.
The output array `s_lerped` is `static vec4_t s_lerped[MAX_VERTS]`, naturally
16-byte aligned.

Monster alias models and the weapon viewmodel rendered with skewed, warped
triangles on mini-g4. World BSP geometry was unaffected (`R_LerpVerts` only runs
for alias models). **The user caught it visually. The bench reported +4.3% fps,
because the broken vertex maths was strictly cheaper than the correct maths, so
the timedemo finished slightly faster.**

The other smoking gun: a second mini-g4 bench at 1024x768 of the **same** binary
that read **103.30 fps** the first time read **17.50 fps** on the retry,
likely the GL driver dropping into a software fallback after the
warped-geometry render corrupted its state.

*Suspected root cause:* `(vector float){a, b, c, d}` constant-init syntax with
`(float)byte` per-lane conversions. gcc-4.0 does compile it, but the
lane-insertion codegen for "3 byte loads + 3 sint→float + 3 vector inserts + 1
literal 0" can go wrong if the compiler uses a stack temp that is not 16-byte
aligned, or emits a `vec_ld` with a wrong shift permute.

*Lessons:* (1) **bench correctness is not visual correctness**, always
corroborate a +N% AltiVec win with a screenshot diff against the scalar
reference, especially in a per-vertex or per-luxel pipeline; (2)
**`(vector float){a,b,c,d}` with non-constant lane values is risky on gcc-4.0
PPC**, prefer writing to a `float v[4] __attribute__((aligned(16)))` stack
buffer then `vec_ld(0, v)`; (3) re-attempting this needs the aligned-stack-load
pattern **plus** a visual A/B from a fixed camera angle, scalar build vs AltiVec
build; (4) watch bench-to-bench stability of the AltiVec slice, rapidly
degrading fps across runs suggests bad geometry is putting the driver in a
degraded mode.

## Assessed and not worth doing

Not failures, but analyses that concluded "no" and should not be re-derived:

- **`frsqrte` `Q_rsqrt_ppc` backport: ~0% framewide.** The per-frame render path
  has only 3 `VectorNormalize` calls (`r_mesh.c`, `r_main.c`, `r_decal.c`),
  saving roughly 25 ns each, about 75 ns per frame, well under 0.01% of a 16 ms
  frame. The 26 calls in `cl_effects.c` are bursty particle spawns and the 7 in
  `pmove.c` run at 10 Hz. Worth doing only for parity with the sister project.
- **AltiVec 16-bit sound mixer: forecast ~1-2% framewide on G4 during heavy
  combat**, 0% while quiet, 0% on Intel (different mixer). Not attempted. The
  real gate would be listening for clipping or phase artifacts, not fps.
- **"GL1 multitexturing" from yquake2-latest is a no-op here.** 5.11 already
  calls `R_RenderLightmappedPoly` via the SGIS multitex path when available
  (`r_surf.c:1172-1228`); the newer tree adds a runtime toggle cvar, not new
  code on the hot path.
- **Cherry-picking yquake2-latest's group-draw wholesale is a multi-day
  hand-port.** It is a 2024 multi-file refactor and every cherry-pick conflicts
  with the `refresh/` → `gl1/` directory rename and the intermingled client
  refactor commits. What shipped here is our own `r_buffer.c` (`gl_groupdraw`).
- **KMQuake2 decals are game-DLL-driven upstream**, `R_AddDecal` is called from
  `g_combat.c` / `p_weapon.c` impact handlers, so a pure renderer port delivers
  nothing without touching `baseq2/game.so` too. This port instead hooks the
  client temp-entity handlers in `cl_tempentities.c`.
- **`demo3.dm2` does not exist in any retail pak.** See ADR 0009.
- **MSAA 4x on an R200 G4 falls off a cliff and breaks the floor.** quicksilver
  (733 MHz PPC 7450, Radeon 9000 Pro 64MB, 10.4.11), demo1 at 1024x768,
  FULLSCREEN, 3 runs each, benchmarks/results.csv 2026-08-22:

      gl_msaa_samples 0    66.15 fps
      gl_msaa_samples 2    57.15 fps   shipped, -13.6%
      gl_msaa_samples 4    31.40 fps   -52.5%, under the 40 fps G4 floor

  So the shipped 2x is the right trade and 4x is not a matter of taste: it puts
  a G4 below its playability floor. The 2x to 4x step costs nearly three times
  what 0x to 2x costs, which looks like the R200 leaving a fast resolve path
  rather than linear sample scaling. Do not raise R200-class machines to 4x.
  The G5's RV350 is a different chip and is not covered by this.

  The mode is stated because it is load-bearing. quake3 measured six settings
  free on a G3 WINDOWED and then -9.7% fullscreen on the same machine, so a
  windowed figure ranks settings but does not say where a floor breaks. These
  are fullscreen: `bench.sh` defaults to `VID_FS=1` / `VID_DFS=0` and passes
  both explicitly on the command line (`bench.sh:149-150`, `:289`), so a
  leftover `config.cfg` cannot change the measured mode. Only `imac-g5`
  deviates, and only to the native-resolution capture path or, with
  `G5_WINDOWED=1`, to windowed. quicksilver is neither.

## Watch items with no recorded failure yet

- `glPolygonOffset` behaviour on the Rage 128 and on Apple's Lion GMA 950 driver
  was flagged as a decal z-fighting risk during the decals port. Nothing has
  been observed; if it appears, the fallback is a per-machine bias cvar rather
  than a global change.
