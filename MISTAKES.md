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

## 2026-05-31 — chased a phantom "G3 corrupt renderer"; real cause was MY stale DMG mounts breaking the deploy (FIXED + a real deploy-verify win)

**The symptom:** while testing v2.2.6, the G3's installed `ref_gl.so` md5'd to
`7dcb39e5…` not the build's `060cc6dc…`, and the in-bundle `quake2` binary went
*missing*. Re-deploys printed `DMG on Desktop verified intact` then **stopped** —
no install, no `done` line.

**The WRONG theory (don't repeat):** I assumed flaky-G3 hardware (old disk /
non-ECC RAM silently corrupting the copy) — the same story as the earlier
DMG-byte-flip. **It was wrong.** The G3 has a near-new SSD. Direct proof: mounting
the on-Desktop DMG on the G3 and hashing its *internal* `ref_gl.so` gave
`060cc6dc…` three times deterministically, and a copy-to-disk hashed clean too.
The hardware reads and copies perfectly. *Lesson: don't reach for "flaky retro
hardware" before proving it — hash the file in place and copy-test it first.*

**The REAL cause:** my own diagnostic `hdiutil attach` commands left the v2.2.6
image **attached** on the G3 (a stale `/dev/disk2` / `/Volumes/Quake2 OldMac
v2.2.6`). `deploy-dmg.sh` mounts the same image at `$HOME/q2install-mnt`; with the
image already attached, that mount came up empty, so `ditto "$MNT/Quake2.app" …`
copied nothing and — under `set -e` — the remote install aborted right after
`rm -rf "$DEST/Quake2.app"`. Result: bundle binary deleted, loose libs left stale
from a prior install. The `7dcb39e5…`/missing-binary state was a half-finished
deploy, not corruption. Force-detaching all images on the G3 and re-running
deployed cleanly; all three machines then verified byte-perfect.

**Two real fixes kept:**
1. `deploy-dmg.sh` now md5-verifies every installed binary (`ref_gl.so`, in-bundle
   `quake2`, `game.so`, `q2ded`) against the mounted image, retries the copy up to
   4×, and fails loud (exit 7). This is the win: it turns a silent half-install
   into a hard error instead of a "done" that lies.
2. Operational: **detach stale mounts before deploying**, and don't leave
   ad-hoc diagnostic mounts of the release image lying around on a target — they
   poison the next deploy's mountpoint. (The deploy already detaches its *own*
   `$MNT`, but not a foreign attach of the same image.)

**Lesson:** verify at the LAST hop the user runs (install dir), not just an earlier
one (DMG-on-Desktop) — the install step had the same blind spot make-dmg already
closed for the image. And: a failing deploy that still prints a success-ish line
is worse than one that errors — the verify gate fixes that.

## 2026-05-31 — `gl_caustics` drew a grid of circles on water: brightness was a PRODUCT of gratings, not a SUM (FIXED v2.2.6)

**The bug:** the `gl_caustics` water overlay (added 12435e1) tiled a tidy grid
of soft round blobs across every water surface — the user read it as
"bullet/shotgun-blast decals repeated all over the water." It showed on BOTH
the G5 (Radeon 9600/Leopard) AND the G3 (Rage 128/Panther).

**Why the both-GPUs fact mattered:** the first instinct (and an Explore agent's
first theory) was a multitexture/TMU state leak from the new `gl_trans_lighting`
path — a *driver-specific* GL-state explanation. But an identical artifact on two
completely different GPUs/drivers means a **deterministic logic bug in shared
code**, not a state leak. That immediately repointed the investigation from
`gl_trans_lighting` to the caustic texture generator. (Also: `d38f7aa`'s own
note says water `SURF_DRAWTURB` early-outs of the lightmap path, so trans-
lighting was never touching water.) Lesson: *same bug on different drivers ⇒
look for logic, not driver state.*

**Root cause:** `R_InitCausticTexture` (`r_misc.c`) computed pixel brightness as
`a*b` — the **product of two sine gratings** — then cubed it. A product of two
gratings peaks at a *regular lattice of isolated points*; cubing sharpened each
peak into a round blob ⇒ a grid of circles. (The comment even *claimed* it made
a "net," but the math made dots.) Real caustics are connected veins, which are
the *zero-crossing contour of a **sum** of waves*, not the product.

**The fix (v2.2.6):** brightness = `1 - |sum_of_sines| / N`, sharpened with a
tunable `pow()` and scaled by a gain — connected wavy ridges = a real caustic
net. Parameterised (`caustic_waves[]` / `CAUSTIC_POWER` / `CAUSTIC_GAIN`) with a
how-to-tweak block; shipped the soft "K" preset. All frequencies are integers so
the tile still wraps seamlessly. Decals (`r_decal.c`) were never involved.

**Tooling note:** to let the user pick a preset, rendered candidate textures to
PNG and opened them in a browser. Snap-Firefox is sandboxed and **cannot read
`/tmp` or anything outside `$HOME`** ("can't find page"); use Chrome, and stage
preview files under `$HOME` (`~/caustic_gallery/`).

## 2026-05-31 — `gl_trans_lighting` port missed a guard → `ERR_DROP` on the first map with non-warp glass (base1) — looked like a fullscreen "crash" (FIXED v2.2.5)

**The bug:** fresh v2.2.4 DMG, verified byte-identical on every machine, yet
"start a new game" **froze** on the G4-mini and the iMac G5 (state `R`/`U`,
pegged CPU, ignored SIGTERM) while the G3 was fine. It looked like a fullscreen /
R300 wedge. It was not. With `logfile 2` flushed, the real cause printed:

```
Outer Base
Map: base1
ERROR: R_BuildLightMap called for non-lit surface     <- r_light.c ERR_DROP
==== ShutdownGame ====
```

`ERR_DROP` longjmps back and drops to a full console; the engine then just
redraws that console forever (`SCR_UpdateScreen → Con_DrawConsole → CGLFlushDrawable`),
which *presents as a freeze*, not a crash — no crash log, process alive, pegged.

**Root cause:** we ported kmquake2's `gl_trans_lighting` (lightmap-modulate
glass/grates). At map load, `r_model.c` calls `LM_CreateSurfaceLightmap` for
`SURF_TRANS33/66` surfaces when the cvar is on; that calls `R_BuildLightMap`.
But `R_BuildLightMap`'s **stock** guard rejects `SURF_SKY|SURF_TRANS33|SURF_TRANS66|SURF_WARP`
as "non-lit". kmquake2 relaxes that exact line to `(SURF_SKY|SURF_WARP)` — we
copied the feature but **not the guard change**, so the feature `ERR_DROP`'d on
the first non-warp translucent surface. base1 ("Outer Base") has glass windows
→ instant drop. base2's translucent surfaces are mostly water (`SURF_DRAWTURB`,
caught by `LM_CreateSurfaceLightmap`'s early-return), which is why a *direct*
`+map base2` could look like it loaded.

**The fix (one line, matches kmquake2):** `r_light.c` guard
`(SURF_SKY|SURF_TRANS33|SURF_TRANS66|SURF_WARP)` → `(SURF_SKY|SURF_WARP)`.
Non-warp trans surfaces carry real BSP lightmap samples and are meant to be lit;
when `gl_trans_lighting` is off they never reach `R_BuildLightMap` anyway.

**Lessons:**
1. **A "fullscreen crash" that leaves a live, pegged process with no crash log is
   almost always an `ERR_DROP` to console — read the flushed log first.** The
   production launch uses `logfile 1` (buffered), so the error never hit disk;
   reproduce with `+set logfile 2` (and `+set vid_fullscreen 0` windowed) to see it.
2. **The architecture split (G3 ok / G4+G5 fail) was a red herring** — it tracked
   *which features the per-machine config enables*, not the CPU. Bisect by the
   actual variable (here: `gl_trans_lighting`), not the coincident one.
3. **`+map base2` ≠ "new game".** The proper first level is `base1`; its content
   (non-warp glass) is what triggered the bug. Test the *real* first map.
4. **When porting a feature, port the whole diff** — including the defensive
   guards it relaxes. A feature copied without its guard change is a latent
   ERR_DROP waiting for the right map.

---

## 2026-05-31 — DMG packaging flipped ONE byte → illegal-instruction crash on the G4 (FIXED v2.2.4)

**The bug:** the v2.2.3 `.dmg` crashed instantly on the G4-mini ("opens then
quits") with `EXC_BAD_INSTRUCTION` / `Code[0]=0x2` (`EXC_PPC_PRIVINST`) at
`Con_Print+8`, deep in `Qcommon_Init → Swap_Init → Com_Printf → Con_Print`.
Disassembling the shipped ppc7400 slice showed a single 32-bit word at that
address had become `0xe7e1fffc` — an undecodable opcode (PPC primary opcode 57,
`lfdp`, 64-bit-only) that traps as privileged on a G4. The INTENDED instruction
was `stw r31,0xfffc(r1)` = `0x93e1fffc` (a register save in the PIC prologue).
**Exactly one byte had flipped: `0x93`→`0xe7`.** The local `build/q2-fat/quake2`
was clean (that byte-flip appeared ZERO times in it); only the DMG copy was
corrupt.

**Why it slipped through:** deploy.sh ships `build/q2-fat` straight to the target
and benched fine; make-dmg.sh takes an extra hop — rsync the staged tree to a
Mac, `hdiutil create` a UDZO, scp it back. The flip happened somewhere on that
hop (almost certainly a RAM/disk glitch on the 1999 non-ECC Panther G3 we were
building the DMG on — TCP+SSH+rsync all checksum the wire, so it was NOT a
transfer-protocol loss). Crucially **`hdiutil verify` did NOT catch it**: it
only checks the UDIF container decompresses to what was stored, not that what
was stored matches the source. And we'd only ever tested with `+timedemo`, never
the actual DMG-installed double-click path, so the corrupt artifact shipped.

**The fix (three parts):**
1. **End-to-end content verification in make-dmg.sh** — after building, mount the
   finished image and md5 `quake2` / `ref_gl.so` / `game.so` *inside it* against
   the source; retry up to 3× and FAIL LOUD if it can't be made byte-identical.
   Corruption on ANY host can never ship again. Also md5-checks the scp-back.
2. **Build the DMG on Tiger, not the G3.** Empirically tested 2026-05-31: Lion's
   hdiutil writes a container Panther can't mount (no flag fixes it — UDZO, UDRO,
   `-layout SPUD` all fail on 10.3.9); a TIGER-built UDZO mounts on Panther →
   modern. So the oldest OS we need for `hdiutil` is Tiger (10.4) — a far
   healthier box than the 1999 G3. `DMG_HOST` now defaults to quicksilver
   (mini-g4 as fallback). The binary is still built on Lion as always.
3. **Test the real artifact.** New `scripts/deploy-dmg.sh` (install from the
   mounted DMG, the way a human does) + `scripts/smoke-dmg.sh` (launch the
   installed copy with the PRODUCTION config, not -noarchautoexec, and auto-exit
   via a demo). The loop is: fix → make-dmg (verified) → deploy-dmg → smoke-dmg
   on G3/G4/G5 → human starts a new game.

**Lesson:** `hdiutil verify` is NOT a content check. Never trust a multi-hop
packaging pipeline to preserve bytes — verify the shipped artifact against the
source byte-for-byte. And don't run the build/packaging on the flakiest hardware
in the fleet when a healthier machine does the same job.

---

## 2026-05-31 — per-machine config applied AFTER CL_Init → refresh-DLL reload → G3 "start a new game" crash (v2.2.x regression, FIXED v2.2.3)

**The bug:** from v2.2.0 ("all fullscreen by default") onward the per-arch
+ per-machine autoexec set `vid_fullscreen 1` / `gl_mode -1` for every box.
Those cfgs were `Cbuf_AddText`'d in `Qcommon_Init` AFTER `CL_Init()` — i.e.
AFTER `VID_Init` had already loaded the renderer in the engine-default
WINDOWED mode. Changing `gl_mode`/`vid_fullscreen` post-init makes
`R_BeginFrame` (r_main.c) escalate the change into a FULL refresh-DLL
reload: it sets `vid_ref->modified`, and the next `VID_CheckChanges`
tears down + reloads `ref_gl.so` via `VID_LoadRefresh`. On the ATI Rage
128 / Panther (G3) that reload path is fatal — `Com_Error` cascade →
`VID_Shutdown` → `R_Shutdown` → `GLimp_Shutdown` → `SDL_GL_SwapBuffers`
on a torn-down context → `EXC_BAD_ACCESS`. Symptom: the menu came up
fine, then **"start a new game" hard-crashed the G3** (the reload fired on
the first rendered world frame). The documented "v2.2.2 / 2nd-launch"
behaviour masked it — and bench/`+set` never tripped it because **`+set`
is an EARLY command** (`Cbuf_AddEarlyCommands`), applied BEFORE
`CL_Init`, so the renderer came up in the final mode with no reload.

**Why earlier attempts missed it:** v2.2.1 validated "start a new game"
but on the G3 used `+set vid_fullscreen 0` (windowed) — which net-cancels
the cfg's `vid_fullscreen 1`, so no mode change, no reload, no crash. The
crash only appears when the cfg actually drives a fullscreen change at
runtime. A `vid_restart`-at-boot workaround (see the entry below) was the
wrong fix — it just forces the same fatal reload deliberately.

**The fix (v2.2.3):** apply the bundle config BEFORE `CL_Init`/`VID_Init`
— relocated in `misc.c` to right after `exec config.cfg` and before
`Cbuf_AddEarlyCommands(true)` (so `+set` still overrides). The cfgs use
`set CVAR VALUE` which creates cvars on demand, so renderer cvars are
picked up unchanged by ref_gl's `Cvar_Get` when it lazy-loads (identical
to how config.cfg's saved cvars already reach the first init). Net: the
renderer comes up in the FINAL mode on the first frame, no reload ever,
on every machine — and per-machine defaults now apply on the FIRST launch.
Defense-in-depth: `GLimp_Shutdown` (refresh.c) now guards its cosmetic
backbuffer clear+swap on a live `surface`, so any future reload can't
re-crash on a stale context.

**Lesson:** on this SDL-1.2 + runtime-loaded-ref_gl engine, NEVER change
`gl_mode`/`vid_fullscreen` after the renderer's first init on the G3 — it
means a full DLL reload, which the Rage 128 can't survive. Get the video
cvars in BEFORE `VID_Init` (like `+set` does). Validated: G3 + G5
start-a-game ALIVE, fleet demo sweep green.

## 2026-05-31 — `killall -KILL` on a fullscreen G5 leaves the screen BLACK (R300 capture not released)

A watch-run killed a fullscreen iMac G5 session with `killall -KILL` only
(no `-TERM` first). SIGKILL skips SDL's shutdown, so the R300/Leopard
captured framebuffer was never released → **black screen** (OS fine, ssh
alive). Recovery: relaunch quake2 and exit cleanly with `-TERM` (SDL
restores the desktop on shutdown). ALWAYS `killall -TERM` (sleep) then
`-KILL` as a backstop — `bench.sh` already does this; the harm came from
an ad-hoc KILL. The Rage 128 G3 tolerates a hard KILL; the R300 G5 does
NOT. See `smoke-test-method` memory.

## 2026-05-31 — first-launch `vid_restart` to apply per-machine defaults crashes Panther/Rage128 (tried in v2.2.2, REVERTED)

**The idea:** the two bundle cfgs (per-arch baseline + per-machine overlay)
are Cbuf'd in `Qcommon_Init` AFTER the initial `VID_Init` (renderer cvars
like `gl_mode`/`gl_customwidth` don't exist until `CL_Init` loads `ref_gl`),
so the per-machine fullscreen + resolution + picmip/retex tune only takes
effect on the 2ND launch (once `config.cfg` has archived the values). To make
it apply on the FIRST launch I added a `vid_restart` after the cfgs load
(guarded by `timedemo==0` so benches aren't re-moded).

**What broke:** it worked on G4 / G5 / Intel, but **hard-crashed the G3**
(yosemite, Panther 10.3.9, ATI Rage 128). Stack (crash.rtf):
`VID_CheckChanges → VID_LoadRefresh → QGL_Shutdown → Com_Error →
VID_Shutdown → R_Shutdown → GLimp_Shutdown → SDL_GL_SwapBuffers` →
`EXC_BAD_ACCESS at 0x134`. The refresh-DLL reload errors out on the old
Rage128/Panther GL stack, and the error-cleanup path calls `GLimp_Shutdown`,
which does `GLimp_EndFrame()` (= `SDL_GL_SwapBuffers`) on an already
torn-down GL context → segfault.

**Why the compile-time guard didn't save it:** I tried
`#if !(defined(__ppc__) && !defined(__VEC__) && !defined(Q2_ARCH_PPC970))`
to exclude the bare-G3 (ppc750) slice. Verified `gcc-4.0 -arch ppc -mcpu=750`
defines only `__ppc__`/`__POWERPC__` (not `__VEC__`), so the macro *should*
exclude it — yet the crash persisted identically. Rather than keep chasing a
fragile per-slice preprocessor guard, the fix was to **drop the vid_restart
entirely**. Per-machine video defaults apply on the 2nd launch on every
machine (reliable); a one-line "nicety" isn't worth crashing the oldest box.

**Lessons:** (a) `vid_restart` (full refresh-DLL reload + SDL video teardown)
is NOT safe to issue automatically on the legacy Panther/Rage128 stack —
treat it as interactive-menu-only there. (b) "tested green on 4 of 5" is not
"works" — the 5th (oldest, least forgiving) is exactly where a video-init
change bites, same lesson as the R300 fullscreen hazard. (c) when a fix needs
a per-slice compile guard to be safe, that's a signal the fix itself is wrong
for this fleet — prefer the mechanism that needs no special-casing.

---

## 2026-05-31 — config comments overflowed the 8 KB command buffer → garbled cfg → R300 GPU wedge on "new game" (shipped in v2.2.0, fixed v2.2.1)

**What shipped broken:** v2.2.0. Starting a new game on the iMac G5 crashed
Quake II, then black-screened the GPU (half-alive wedge, recovered with an
SSH `sudo reboot`). The bench grid had been all green — because it only ever
ran **timedemos**, never an actual new game.

**Root cause:** the two-layer bundle config system Cbuf_AddText's the
per-arch baseline AND the per-machine overlay back-to-back, before
execution, into a FIXED 8 KB buffer (`cmd_text_buf[8192]`, cmdparser.c).
This round I added verbose documentation comments + Display sections to the
cfgs, pushing each file to 4.7–7.3 KB. Two of them together exceeded 8 KB on
**every** machine (G5: 4696 + 6772 = 11,468) → `Cbuf_AddText: overflow`. The
engine drops the overflowing text and the parser desyncs: leftover comment
words get executed as commands (`Unknown command "the"/"real"/"this"`,
`Line has unmatched quote, discarded`), and the overlay lands only partially.
The resulting inconsistent renderer cvar state was survivable on a timedemo
flythrough but wedged the R300 driver on a real map-load render.

**Why it slipped through:** classic "load-time only / zero risk" smell-test
failure — *comments in a config file* look about as harmless as a change can
get. Two compounding blind spots: (1) the cfgs are appended to a small fixed
engine buffer, so even inert comment bytes have a hard budget; (2) I
validated exclusively with `+timedemo`, which never spawns the player/world
the way "new game" does, so the corrupted-state crash never fired in testing.

**The fix (two layers, v2.2.1):**
1. **Ship comment-stripped cfgs.** deploy.sh + make-dmg.sh now pipe each cfg
   through `sed 's,//.*,,' | grep -v '^[[:space:]]*$'` when copying into the
   bundle — the repo files keep all their docs, the shipped files are ~1–2 KB
   of bare `set` lines (combined ~2 KB, vs the 8 KB limit). Verified the strip
   preserves every `set` command across all 11 cfgs.
2. **Bump the buffer 8 KB → 64 KB** (`cmd_text_buf`/`defer_text_buf`,
   cmdparser.c) as belt-and-suspenders so a future un-stripped or grown cfg
   can't overflow.

**Lessons:** (a) shipped config text has a hard size budget when the engine
buffers it — keep shipped cfgs lean (strip comments) and don't trust "it's
just a comment". (b) A timedemo is NOT a substitute for actually starting a
new game when validating render/gameplay paths — test the thing the user
does. (c) When a change is "harmless everywhere", check the one machine with
the least forgiving driver (the R300) — it turns soft failures into hard ones.

---

## 2026-05-31 — iMac G5 (ATI R300 / Leopard): non-native fullscreen mode-switch HARD-HANGS the whole OS

**What would have gone wrong:** the stock `bench.sh` / `screenshot.sh`
launch the engine with `vid_fullscreen 1` + `gl_mode -1` + a non-native
`gl_customwidth/height` (e.g. 1024x768 or 640x480). On every other box
that's fine. On the iMac G5 (`PowerMac8,2`, ATI Radeon 9600 / RV351,
Mac OS X 10.5.8) it is a landmine: the R300 Leopard driver **hard-hangs
the entire OS** on a fullscreen video-mode *switch* to a non-native size.
Not a crash — a full GPU/kernel lockup: grey screen, no ping, no SSH,
fans ramp to max (the SMU thermal failsafe). Recoverable ONLY by the
physical power button. Benching the G5 headless with the stock scripts
would have bricked it with no remote recovery.

**Root cause:** discovered first on the QuakeSpasm sister port (see
`docs/imac-g5-leopard-port-notes.md`). The R300 is the only fleet GPU
advertising GL2.0, and its Leopard driver mishandles fullscreen mode
switches (and GLSL/VBO, which our `ref_gl` doesn't use — verified: no
VBO/FBO/GLSL/NPOT/auto-mipmap in `src/refresh/`, so that half of the
QuakeSpasm bug doesn't apply to us; only the mode-switch half does).

**The fix:** never switch modes on the G5 — do a same-mode *display
capture* at the panel's native resolution instead.
- New engine cvar `vid_desktopfullscreen` (`r_main.c` + `backends/sdl/
  refresh.c`): captures the desktop res at SDL video init and substitutes
  it for the requested size when fullscreen, so SDL captures the current
  mode with no switch. Auto-picks 1440x900 (17") / 1680x1050 (20").
  Default off — zero effect on every other machine. ON in the `ppc970`
  baseline + `imac-g5` overlay.
- `bench.sh`: on `imac-g5`, REFUSES non-native fullscreen (`exit 3`),
  defaults to native-res capture (`vid_desktopfullscreen 1`), and offers
  `G5_WINDOWED=1` for safe windowed iteration. Both vid cvars are set
  explicitly on the cmdline so a leftover archived value can't change the
  measured mode.
- `screenshot.sh`: same — native capture on the G5, never a mode switch.
- `parallel-bench.sh`: the G5 leg benches at native `1440x900`, not the
  shared 1024x768/640x480 sweep (which it would refuse).

**Lesson:** the "load-time only / zero risk" smell test failed here — a
one-line resolution flag that is inert everywhere else can take a whole
machine down on one specific GPU+OS. When adding a box with a
new-to-the-fleet GPU/OS combo, assume the fullscreen path is the first
thing that will bite, and validate it windowed / same-mode before ever
triggering a remote mode switch you can't physically recover from.

---

## 2026-05-29 — fixed-function bloom: too slow on PPC + R_LoadPic eats the screen texture

**What we tried:** a fixed-function light bloom post-process (`r_bloom.c`,
`gl_bloom`) — capture the back buffer with `glCopyTexSubImage2D`, downsample
into a small effect texture, darken to isolate brights, separable blur,
additive composite. No ARB_fragment_program/FBO (the KMQuake2 base bloom is
pure fixed-function). Hooked at the end of `R_RenderView`.

**What went wrong:**
  1. **Prohibitively slow on the 2001 GPU.** quicksilver R9000 Pro: 66.95 →
     **25.50 fps** demo1 1024 (−62%) — below even the relaxed ~40fps G4
     tolerance. The per-frame fullscreen copy + multiple sample passes are
     fillrate murder on a 1999-2005 part.
  2. **Visually broken on GMA 950 / Lion.** First cut left the bloom
     workspace (rendered into the back-buffer bottom-left corner) visible as
     a black box + a heavy additive wash. Adding a "restore the scene from
     the captured screen texture, then add bloom" blit fixed the corner in
     principle but the **whole 3D scene came back black** — almost certainly
     because `R_LoadPic(..., it_pic, ...)` RESIZES/repacks a large (1024²)
     pic texture, so the `glCopyTexSubImage2D` capture region overflows the
     real texture and the copy silently stays empty (memset 0).

**Resolution:** shipped DISABLED (`gl_bloom 0` everywhere, binary default 0).
Code kept in-tree as wired WIP. **Lessons:** (a) a fullscreen post-process is
the wrong shape for the PPC fillrate budget — needs sub-res / tiny
`gl_bloom_size` and probably only ever makes sense on the iMac. (b) Don't use
`R_LoadPic`/`it_pic` for a render-target — it applies pic resizing/scrap
logic; a bloom redo needs a dedicated full-size texture created straight via
`qglTexImage2D` so `glCopyTexSubImage2D` has a matching destination.

---

## 2026-05-29 — procedural/effect textures get freed on map change unless protected

**What we tried:** `gl_glows` and `gl_caustics` build a procedural texture
once at `R_Init` (in `R_InitParticleTexture`) and stash the `image_t*` in a
global (`r_shelltexture`, `r_caustictexture`), exactly like `r_particletexture`.

**What went wrong (latent):** `R_FreeUnusedImages` (run on every map change)
frees any image whose `registration_sequence` != the current one. The two new
textures were NOT in the protect list, so they'd be freed on the first map
change and the feature paths would then bind a deleted texnum. It did NOT
surface in the demo1 bench/screenshots only because those frames barely
exercise the shell/caustic paths — a real "looked fine, was broken" trap.

**Fix:** protect them in `R_FreeUnusedImages` the same way `r_notexture` /
`r_particletexture` are (bump `registration_sequence`). **Lesson:** any
texture created once at init and held in a global MUST be added to the
`R_FreeUnusedImages` protect block, or it dies at the next map load.

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

## 2026-05-23 — Bench machine state can shift between runs (thermal, vsync)

**What we observed:** mini-g4 produced 97.50 fps demo1 1024×768 early in
the session, then 56.8 fps later in the same session — same binary,
same code, same autoexec. A clean reboot of the machine did not
restore the original fps. Diagnostic checks confirmed:
- top showed 0% idle CPU
- display mode was still 1024×768 @ 60 Hz
- GL_RENDERER reported the R9200 normally
- demo1 ran 689 frames in 12.1 seconds (was 7.1 s)

The 56.8 fps figure is suspiciously close to `60 × 16/17 = 56.5`,
suggesting Quartz vsync had taken effect (engine missing one of every
17 swaps) — but explicit `SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, 0)`
didn't recover it. Windowed mode was actually slower (44 fps), so it
wasn't purely a fullscreen vsync issue either.

Most likely cause: thermal throttling on the 1.25 GHz 7447A. Tiger
does not manage CPU temperature actively; sustained benchmarking can
push the part into thermal limit. The 7447A's clock-throttle ramps it
down to ~800 MHz when hot, which roughly matches the 60% fps fall.
A 30+ minute cool-down (or running the machine off and unplugged)
typically resolves it.

**Fix:** Wait for the machine to cool. Don't bench-validate code
changes against numbers from a hot machine. For overnight automated
runs, leave a cool-down gap between batches.

**Defensive code change shipped:** explicit `SDL_GL_SWAP_CONTROL` to
0 when `gl_swapinterval` is 0 (was previously only set when 1) — this
prevents the OS default kicking in unpredictably across reboots.

**Lesson:** Benchmark numbers from this fleet need a "thermal-OK" tag.
A regression vs an earlier number isn't always a code regression — if
the same binary produces both numbers on the same machine, it's
state. Re-validate after a cold-boot rather than chasing it in code.

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


