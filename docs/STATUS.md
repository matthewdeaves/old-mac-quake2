# Status / changelog — yquake2 PPC port

Append-only project history (newest at the bottom of each round). CLAUDE.md
keeps only the one-line "current / next"; the full narrative lives here. For the
roadmap see `PPC_PLAN.md`; for things that went wrong see `MISTAKES.md`.

- 2026-05-11: Phase A landed. Self-contained fat universal `Quake2.app`
  ships to all 6 bench machines (yosemite/sawtooth/quicksilver/mini-g4/
  mini-intel/imac-2019). Per-machine autoexec layer loaded via CFBundle
  works on PPC (Tiger + Panther), Intel Lion, and Intel Sequoia. TGA
  screenshot writer patched for top-down orientation.
- 2026-05-19: imac-2019 baseline captured — 701.6 fps @ 1024×768,
  709.2 fps @ 640×480 (Polaris 20 totally unbound by GL1 fixed-func).
  Phase A baseline now complete across all 6 machines; tagged `v1.0.0`
  as the canonical re-bench reference build.
- 2026-05-21: Phase B/C cherry-pick round landed. `gl_fog` (cvar-driven
  GL_FOG, ported from KMQuake2), `gl_waterwarp` (underwater frustum
  sine-warp), `gl_lightmap_subrect` (dirty-column-only dynamic upload),
  `jpeg.c` rewritten on stb_image (drops libjpeg, unlocks
  `WITH_RETEXTURING` on every slice), `gl_groupdraw` cvar +
  `r_buffer.c` (batched `qglDrawElements` dispatch per state group),
  and a CFBundle HD-texture search path in `FS_InitFilesystem` so a
  pack can ship inside the .app. THE KEY FIX of the round was
  `78c26f2`: `R_ApplyGLBuffer` must not toggle `R_EnableMultitexture` —
  doing so resets TMU1's TexEnv to `GL_REPLACE`, destroying the
  `GL_COMBINE_EXT` modulate setup `R_DrawWorld` put in place and
  rendering walls/floors as overbright lightmap-only (with OBB4 → flat
  yellow/beige). The buffer must trust the outer code to own the mtex
  enable lifecycle. See `r_buffer.c` for the load-bearing comment.
  Post-fix every multitex platform (mini-g4 / quicksilver / mini-intel)
  renders correctly with full retex + OBB4. Yosemite ULTIMATE shipped
  (25.10 / 45.15 fps with picmip 0 + trilinear + alias shadows + fog).
- 2026-05-29: v2.1.0 round (tagged). Shipped: `gl_glows` (sphere-map
  energy shell), `gl_trans_lighting` (lightmapped glass/grates),
  `gl_caustics` (water-surface caustic overlay) — all ON for the multitex
  boxes, OFF on yosemite/sawtooth; `gl_zfix` (coplanar z-fix) everywhere;
  `gl_farsee` on the x86 boxes; CVA (`glLockArraysEXT`) on the group-draw
  path (fps-neutral, kept for parity). Fixed a latent bug: the procedural
  shell/caustic textures (and bloom's) are now protected in
  `R_FreeUnusedImages` — they were being freed on map change. `gl_bloom`
  (fixed-function light bloom) is wired but DISABLED — prohibitive on PPC
  (quicksilver 25fps) and renders incorrectly on the GL1 path; see
  MISTAKES.md. `scripts/make-dmg.sh` added (Panther-built UDZO `.dmg`).
  Note: G4 fps floor is now ~40 for feature work (user pref), not 60.
- 2026-05-31: iMac G5 (PowerMac8,2, 970FX @ 2.0 GHz, Leopard 10.5.8)
  added as a 4th PowerPC fat slice (branch `imac-g5-target`). New `g5`
  build target (10.5 SDK, `-mcpu=970 -maltivec -DQ2_ARCH_PPC970`), 4-way
  lipo in `build-fat.sh` (ppc750+ppc7400+ppc970+x86_64). Also closed a
  gap vs the QuakeSpasm design: Q2 previously had ONLY the per-machine
  (hw.model) config layer, so unknown Macs got stock yquake2 defaults.
  Added the **per-arch baseline layer** (`autoexec-ppc750/ppc7400/ppc970/
  x86_64.cfg`, compile-time selected in `misc.c`) so ANY G3/G4/G5/Intel
  Mac now gets a sane generic tune, with the per-machine overlay still
  winning on the six known boxes. ppc970 baseline seeded conservatively
  from the proven ppc7400 tune (won't regress). **DEFERRED until the iMac
  G5 is on the network:** confirm exact hw.model + GPU via SSH; add
  per-machine `autoexec-imac-g5.cfg` + a `PowerMac8,2` entry to the
  hw.model map in `misc.c`; add an `imac-g5` HOST case to `deploy.sh`;
  wire SSH config (Leopard OpenSSH may need the legacy-crypto block);
  ship game data; first bench. Build/lipo verified offline (all four
  slices present); no runtime test yet (no G5 reachable).
- 2026-05-31 (later same day): **iMac G5 networked + bring-up landed**
  (branch work on top of `imac-g5-target`). Confirmed `hw.model`
  `PowerMac8,2`, GPU ATI Radeon 9600 (RV351) 128 MB, 10.5.8 (9L31a), 17"
  native 1440×900, SSH alias `imac-g5` (user `imacg5`, legacy-crypto
  block). Wired: `PowerMac8,2`→`autoexec-imac-g5` in the `misc.c` hw.model
  map; new `autoexec-imac-g5.cfg` overlay (most-capable PPC tune — picmip0,
  retex, 16x AF, dynamic lights, glows/trans_lighting/caustics, OBB4, decals
  64, 44 kHz; A/B notes for stencil shadows + 4x MSAA); `imac-g5` cases in
  `deploy.sh` / `bench.sh` / `screenshot.sh` / `make-dmg.sh` /
  `parallel-bench.sh`. Pulled the **ppc970 Leopard SDL 1.2.15 slice** into
  our `SDL.framework` (now 4 slices). **Ported the QuakeSpasm Leopard/R300
  fix:** new `vid_desktopfullscreen` engine cvar (`r_main.c` +
  `backends/sdl/refresh.c`) = native-res same-mode capture, the only
  fullscreen path the R300 driver survives; ON for iMac-class boxes.
  Hardened `bench.sh`/`screenshot.sh` to refuse / never trigger a non-native
  fullscreen mode switch on the G5 (would hard-hang the OS — see MISTAKES.md
  + `docs/imac-g5-leopard-port-notes.md`). Fat binary rebuilt (4 slices,
  ppc970 carries the new map + cfg). **DEPLOYED + BENCHED** (later 2026-05-31,
  after the QS bench freed the box). Renderer confirmed `ATI Radeon 9600
  OpenGL Engine / 2.0 ATI-1.5.48`, desktop-capture logged `Desktop is
  1440x900`, native same-mode fullscreen validated (SSH survived — no R300
  hang). Findings: demo is **CPU-bound on the 970FX** — ~116/114 fps (demo1/
  demo2) flat across 640×480 / 1024×768 / native 1440×900. **Stencil shadows
  are FREE** (116.1 vs 115.9 — the R9200/Tiger 60% cliff is absent on 9600/
  Leopard) → enabled. **MSAA is fillrate-bound at native**: 0x=116, 2x=52.5,
  4x=27 fps; per user pref (visuals over fps, ~50 ok) shipped **2x MSAA**.
  Final production render (native 1440×900, full tune + stencil + 2x MSAA):
  **demo1 52.6 / demo2 51.7 fps**.
- 2026-05-31 (release round, v2.2.0): hardened + generalised the G5 work into
  a shippable release.
  * **Engine defense-in-depth:** `GLimp_ForceDesktopFullscreen()` (refresh.c)
    detects the iMac G5 family by `hw.model` (pre-GL, so it protects the very
    first VID_Init) and forces same-mode desktop CAPTURE for EVERY fullscreen
    request, independent of cvar/config. PROVEN with a pathological-config
    audit: planted `vid_fullscreen 1 + vid_desktopfullscreen 0 + non-native
    1024x768` in config.cfg, launched with the overlay disabled — the engine
    logged the requested 1024x768 mode but captured native 1440×900 and the
    OS did NOT hang. This closes the exact QuakeSpasm Finder-double-click bug.
  * **Fleet "all fullscreen by default" policy** (user request): every per-arch
    baseline (ppc750/ppc7400/ppc970/x86_64) now defaults to fullscreen at the
    panel's NATIVE res via desktop-capture (auto-fits any unknown G3/G4/G5/Intel
    iMac); every known fleet tower/mini/modern overlay pins a validated SPECIFIC
    res (1024×768 PPC + GMA, 1920×1080 imac-2019 — native 5K × 8× MSAA would be
    a ~100× fillrate cliff). Bench/screenshot still own the measured mode via
    cmdline +set, so this is fps-neutral to benchmarks (verified: mini-g4 57.2,
    mini-intel 97.9, yosemite 31.9 — all in line with prior baselines).
  * **Validated** end-to-end: G5 production double-click → native fullscreen
    capture, no hang; fleet regression clean; G5 production tune 52.6/51.7 fps.
  * Tagged v2.2.0, DMG cut on Panther, pushed. Bench machines shut down after.
- 2026-05-31 (v2.2.1 hotfix): **v2.2.0 crashed on "start new game" on the iMac
  G5** (R300 GPU wedge). Root cause: the two-layer bundle config (baseline +
  overlay) is Cbuf_AddText'd into a fixed 8 KB buffer; my verbose cfg comments
  pushed the two files >8 KB on EVERY machine → `Cbuf_AddText: overflow`,
  garbled config, inconsistent renderer state that the R300 couldn't survive on
  a real map load. Missed because I only validated with `+timedemo`, never an
  actual new game. Fix: (1) ship comment-STRIPPED cfgs (deploy.sh + make-dmg.sh
  `sed 's,//.*,,' | grep -v '^$'` → ~2 KB combined; repo files keep their docs);
  (2) bump `cmd_text_buf`/`defer_text_buf` 8 KB→64 KB (cmdparser.c) as
  belt-and-suspenders. Validated a real **new game (base1) on every GPU class**
  (Rage128/Panther, GeForce2/Tiger, R9000/Tiger, R9200/Tiger, GMA950/Lion,
  R300/Leopard) — all load the map, no overflow, no crash. Also corrected the
  G5 production numbers: the overflow had been DROPPING the imac-g5 overlay, so
  earlier benches missed stencil/glows/caustics. True production (native 1440×900,
  full stack + 2× MSAA, user-confirmed): **46.8/45.8 fps** (demo1/demo2); ~100
  fps with MSAA off. See MISTAKES.md (2026-05-31 Cbuf entry). Tagged v2.2.1.
- 2026-05-31 (v2.2.2): config-only round on the proven (two-launch) engine.
  yosemite kept at 1024x768 (25.2 fps, above floor, user choice); **both Intel
  boxes now carry the full visual stack** — mini-intel gained stencil shadows +
  8x MSAA (benched FREE on the GMA950 — demo is CPU-bound) + 128 decals (aniso
  stays 8 = GMA950 hw cap), matching imac-2019. NOTE: a first-launch
  `vid_restart` (to apply per-machine fullscreen+res on the 1st launch instead
  of the 2nd) was implemented, tested green on G4/G5/Intel, but **REVERTED** —
  it hard-crashes Panther/Rage128 (the G3): GLimp_Shutdown -> SDL_GL_SwapBuffers
  on a torn-down context during the refresh-DLL reload (crash.rtf / MISTAKES.md).
  Per-machine video defaults therefore apply on the **2nd launch** (1st launch =
  engine-default windowed; relaunch = the tuned fullscreen+res). Reliable on all
  5 GPU classes. (v2.2.2 was documented but never tagged — the G3 "start a new
  game" crash below was still live in it.)
- 2026-05-31 (v2.2.3): **THE G3 START-A-GAME CRASH IS FIXED, + WASD/mouse-look,
  + first-launch defaults.** Root cause: the per-machine autoexec was applied
  AFTER CL_Init (post renderer-init), so its `vid_fullscreen 1`/`gl_mode -1`
  escalated into a full refresh-DLL reload (`R_BeginFrame`→`vid_ref->modified`→
  `VID_LoadRefresh`), which is FATAL on the Rage128/Panther (GLimp_Shutdown→
  SDL_GL_SwapBuffers on a torn-down context). The menu came up, then "start a
  new game" hard-crashed the G3. Fix: **apply the bundle config BEFORE CL_Init/
  VID_Init** (misc.c — right after `exec config.cfg`, before
  `Cbuf_AddEarlyCommands(true)` so `+set` still wins). The `set CVAR VALUE`
  syntax creates cvars on demand, so ref_gl picks them up via Cvar_Get on lazy-
  load (same as config.cfg). Net: renderer comes up in the FINAL mode on the
  first frame, **no reload ever, on any machine** — and per-machine defaults
  (incl. fullscreen + res) now apply on the **FIRST launch**. Also: the old
  reverted first-launch `vid_restart` is gone; `GLimp_Shutdown` now guards its
  cosmetic clear+swap on a live surface (defense-in-depth). **New WASD + mouse-
  look default control scheme** (shared `autoexec-controls.cfg`, parity with the
  QuakeSpasm fleet build: W/S forward-back, A/D strafe, mouse freelook, SPACE
  jump, C crouch — overrides stock yquake2's ESDF layout). G5 video cvars made
  deterministic (`gl_mode -1` + native dims, no stale config.cfg leak). Validated
  end-to-end: G3 + G5 **start-a-game ALIVE** (in-game world render, correct res),
  full fleet demo sweep green and user-confirmed (yosemite 1024×768 25fps;
  quicksilver 64.0; mini-g4 56.8; mini-intel 94.8; imac-g5 native 1440×900 30fps
  w/ 2× MSAA). DMG cut + shipped to every desktop. Tagged v2.2.3.
- 2026-05-31 (v2.2.4): **DMG packaging integrity + a healthier build host.** The
  v2.2.3 *binary* was correct (deploy.sh + bench were clean), but the v2.2.3
  *DMG* shipped a single flipped byte in the ppc7400 slice's `Con_Print` (a PIC-
  prologue `stw r31` → an undecodable 64-bit opcode) → `EXC_PPC_PRIVINST` insta-
  crash on the G4-mini at startup. The flip happened in the DMG hop (RAM/disk
  glitch on the 1999 Panther G3 we were building the image on); `hdiutil verify`
  doesn't catch it (it only checks the container, not source fidelity). Fixes:
  (1) `make-dmg.sh` now does **end-to-end content verification** — mounts the
  finished image and md5s `quake2`/`ref_gl.so`/`game.so` inside it against
  source, retries 3×, fails loud; plus an scp-back md5 check. (2) **DMG host
  moved off the G3 to Tiger** (`DMG_HOST` default → quicksilver, mini-g4
  fallback): empirically, Lion's hdiutil can't write a Panther-mountable image
  (UDZO/UDRO/`-layout SPUD` all fail on 10.3.9) but a Tiger-built UDZO mounts
  Panther→modern, and Tiger is far healthier hardware than the 1999 G3. Binary
  still built on Lion. (3) New `scripts/deploy-dmg.sh` (install from the mounted
  DMG like a human) + `scripts/smoke-dmg.sh` (launch the installed copy with the
  PRODUCTION config — not -noarchautoexec — and auto-exit via a demo). Validated
  end-to-end: v2.2.4 DMG (verified byte-identical to source) installed from the
  mounted image + production-launched on G3 (1024×768 Rage128, 20.6 fps), G4-mini
  (1024×768 R9200, 38.5 fps), G5 (native 1440×900 capture R9600, 30.0 fps, no
  R300 hang) — all rendered the demo to completion. See MISTAKES.md (DMG byte-
  flip entry). Tagged v2.2.4.

## Foundations (one-time facts)
- yquake2 cloned at QUAKE2_5_11 tag (commit `033550cd`, 2013-05-20).
- Reference repos cloned for Phase B (yquake2 latest) and Phase C
  (KMQuake2 visual features, FoD Q2 Mac Cocoa patterns).

## Next
- bloom redo (dedicated render-target texture, sub-res budget);
  AltiVec `R_BuildLightMap`; GL1 gamma correction; re-bench mini-g4 cool.
