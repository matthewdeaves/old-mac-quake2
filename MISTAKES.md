# Mistakes

Settled negative results; search by ticket or date before retrying an optimisation.
Archive: `docs/archive/MISTAKES.md`. Topic lookup: `docs/mistakes/`.
Cross-port benchmark/SDL lessons: `../old-mac-quakespasm/MISTAKES.md`.
Dates added to undated accounts identify their recorded evidence or first Git record, not a newly inferred incident date.

## 2026-09-28 `frsqrte` `Q_rsqrt_ppc` backport: about 0% framewide
The per-frame render path has only 3 `VectorNormalize` calls (`r_mesh.c`, `r_main.c`, `r_decal.c`), saving roughly 25 ns each, about 75 ns per frame, well under 0.01% of a 16 ms frame. The 26 calls in `cl_effects.c` are bursty particle spawns and the 7 in `pmove.c` run at 10 Hz. Only worth it for parity with the sister project.

## 2026-09-28 AltiVec 16-bit sound mixer: forecast 1-2% framewide on G4
Only during heavy combat; 0% while quiet, 0% on Intel (different mixer). Not attempted. The real gate would be listening for clipping or phase artifacts, not fps.

## 2026-09-28 "GL1 multitexturing" from yquake2-latest is a no-op here
5.11 already calls `R_RenderLightmappedPoly` via the SGIS multitex path when available (`r_surf.c:1172-1228`); the newer tree adds a runtime toggle cvar, not new hot-path code.

## 2026-09-28 Cherry-picking yquake2-latest's group-draw wholesale is a multi-day hand-port
A 2024 multi-file refactor; every cherry-pick conflicts with the `refresh/` to `gl1/` rename and the intermingled client refactor commits. What shipped is our own `r_buffer.c` (`gl_groupdraw`).

## 2026-09-28 KMQuake2 decals are game-DLL-driven upstream
`R_AddDecal` is called from `g_combat.c`/`p_weapon.c` impact handlers, so a pure renderer port delivers nothing without touching `baseq2/game.so`. This port instead hooks the client temp-entity handlers in `cl_tempentities.c`.

## 2026-09-28 `demo3.dm2` does not exist in any retail pak
See ADR 0009.

## 2026-09-28 Stubbing the network does not make a build script safe to run
`scripts/build.sh:247` is `rm -rf "$REPO_ROOT/build/q2-$TARGET"`, running long before anything touches a mini. A test with `rsync` and `ssh` stubbed on `PATH` reached it and deleted a real `ppc7400` slice; the stubbed fetch replaced nothing, leaving a `SOURCE-STAMP` with no binary. `build/q2-fat` was already fused so nothing shipped wrong, but the intermediate had to be rebuilt. Run a build script against a COPIED tree with its own `REPO_ROOT`, never the live one (`build.sh` only needs `scripts/` and a writable `build/`).

## 2026-09-28 Backticks in `git commit -m "..."` RUN as commands
A commit message quoted a filing recipe inside backticks inside a double-quoted `-m`; the shell substituted it, so `gh issue create --project Retro` was EXECUTED. Nothing was created only because `gh` refuses without `--title`/`--body` non-interactively. The commit pushed with the text deleted ("It taught ,"). Commit messages here routinely quote shell: write them with a quoted heredoc (`git commit -F - <<'MSG'`). Never `-m` with backticks.

## 2026-09-28 `git add -A scripts/` swept another session's files into an unrelated commit
old-mac-build-host synced both host pickers into this tree with `sync-build-lock.sh --write` mid shellcheck triage; `git add -A scripts .github` took all of it, so `d25f2b81` carries 122 lines of picker changes under a shellcheck-only message, pushed before anyone looked. Code was good; the record was wrong and pushed history cannot be rewritten. Nothing arbitrates working trees, only machines. Stage by name, or read `git status` immediately before `git add`; never `-A` on a directory a sync targets.

## 2026-09-28 A check that cannot read its input still prints a pass
Three in one session: `grep -rlE ... scripts | wc -l` gave `0` one-argument call sites while the dir was unreadable; `for spec in "a b c"` under zsh did not word-split, so six scripts ran under one garbage name and every case read "skipped"; `git show ... 2>&1 | shasum` hashed error text into a plausible `db132943...` when the real answer was `e3b0c442...` (sha256 of empty). Redirect stderr separately, assert the input is readable and non-empty, and prove a negative check still FIRES on known-bad input before believing a clean run.

## 2026-09-28 Per-machine config applied AFTER `CL_Init` hard-crashed the G3 on "new game"
The refresh-DLL reload it triggered crashed the Panther/Rage 128 G3 on "start a new game". Root cause and fix: ADR 0007.

## 2026-09-28 iMac G5 R300/Leopard driver hard-hangs the OS on a non-native fullscreen switch
Hazard, mitigations and never-bypass rule: ADR 0008. The "load-time only / zero risk" smell test failed: a one-line resolution flag inert everywhere else took a whole machine down on one GPU + OS combination. Adding a box with a new-to-the-fleet GPU/OS pair: assume the fullscreen path bites first; validate windowed or same-mode before any remote mode switch you cannot physically recover from.

## 2026-09-28 `killall -KILL` on a fullscreen G5 leaves the screen BLACK
The R300 display capture is never released. Always TERM, sleep, then KILL: ADR 0008.

## 2026-09-28 `glPolygonOffset` on Rage 128 and Apple's Lion GMA 950 driver
Flagged as a decal z-fighting risk during the decals port. Nothing observed; if it appears, the fallback is a per-machine bias cvar rather than a global change.

## 2026-09-22 Offscreen bloom workspace: too little benefit on GeForce 9400
Native 1920x1080, requested MSAA2, bloom256/darken4: single-sample renderbuffer copies demo2 A/B/B/A 48.30/48.85/48.65/48.20 fps; direct texture ping-pong 47.40/50.15/49.30/48.75 (demo2), then 50.25/50.65/50.90/49.95 (demo1). Small benefit, only 0.675 fps between demo1's averaged warm legs. Reverted the FBO code rather than ship extra legacy-driver paths for it; does not rule out a different approach to the full-resolution capture/composite. Evidence and recoverable patches: `framebuffer/intel-fbo`.

## 2026-09-22 Raising GeForce 9400 MSAA with bloom spends too much headroom
Native 1920x1080, optimized bloom on, demo2 MSAA2 vs MSAA4: warm 48.25 vs 30.40 fps (three runs each). Selected frames show only modest edge changes; keep 2x. Cvar requests verified; this runtime did not log the driver's actual sample count. Evidence: `benchmarks/experiments/2026-09-22-framebuffer/intel-aa/`.

## 2026-09-22 Indexed-model range hints did not improve the Radeon 9200
Optional `glDrawRangeElements` with known model/shadow vertex bounds instead of `glDrawElements`. 1024x768, combined clears, MSAA2, projected shadows: demo1 A/B/B/A warm 55.65 / 55.70 / 55.70 / 55.70 fps; ten captured frame pairs pixel-identical. Reverted; no new setting earns a default. Evidence and rejected patch: `benchmarks/experiments/2026-09-22-framebuffer/g4-drawrange/`.

## 2026-09-22 G4 bloom still breaks the playable floor after framebuffer optimizations
Radeon 9200 mini-G4, 1024x768, MSAA2 and stencil shadows kept: combined clears lift bloom-off demo1 from 40.60 to 55.70 fps. Bloom with partial restoration and darken=4 costs 18.15 fps at bloom-size 128 and 15.10 at 256 (warm means, three runs each). Keep bloom off; smaller blur work and the new clear path do not make the full-screen capture/composite affordable. Does not negate the GeForce 9400 partial-restoration win.

## 2026-09-22 G4 stencil-operation and submission experiments did not win
Shadow coverage `GL_INCR` to `GL_ZERO`: same pixels, unchanged 40.60 fps (A/B/B/A). Reverted. Compiled-array locking 34.80 vs 40.60 fps; retained-world VBO submission 40.65 vs 40.60 (noise). No new default. Combining depth/stencil clears was the win in this driver, not shadow geometry or the stencil op.

## 2026-09-13 Forcing 16-bit `gl_texturesolidmode`/`gl_texturealphamode` helped the G3, cost the G4 (#69)
#68 found `GL_EXT_paletted_texture` and `GL_EXT_shared_texture_palette` absent on both the G3's Rage 128 and the G4's Radeon 9200, so `gl_ext_palettedtexture 1` is a no-op on both and both fall to `"default"`. On the G3 forcing `GL_RGB5`/`GL_RGBA4` was a clean +13.3% (25.85 to 29.30 fps, bit-identical x3). Same override on mini-g4: **-12.2% (40.25 to 35.35 fps)**, noisy (35.5/36.3/34.4). Why: the Rage 128's `"default"` happened to be worse than an explicit 16-bit request; the RV280's is apparently already efficient and forcing a format adds a conversion step. Same absent-extension reasoning, opposite driver behaviour: bench every class separately. Reverted (EXTRA-only, nothing in mini-g4's shipped cfg). Evidence: `benchmarks/results.csv` (`3f6cf8b9`/mini-g4 rows), #69.

## 2026-08-28 create-dmg adoption rejected (#39)
Considered build-host's `create-dmg` drag-to-Applications layout (`lay-out-dmg.sh`); rejected without shipping. It needs Homebrew and a live Finder, so it must run on a modern host, but `make-dmg.sh` runs `hdiutil create` on a Tiger G4 (`quicksilver`/`mini-g4`) because Lion's `hdiutil` writes a UDIF container the Panther G3 cannot mount, and no flag fixes it (ADR 0005, measured). A modern host (the workstation is macOS 26, 14 years newer than the proven-bad Lion case) reintroduces that break, worse: a newer container format never regains old-OS readability. Not live-retested on Panther (`yosemite` was mid-OS-switch); inferred from ADR 0005, and the direction only worsens with a newer host. A second modern-only DMG just for the layout was rejected as unrequested complexity for one fat cross-arch release.

## 2026-05-29 (updated 2026-08-23, #33) Fixed-function bloom: too slow on PPC, and `R_LoadPic` eats the screen texture
`r_bloom.c`/`gl_bloom`: capture the back buffer with `glCopyTexSubImage2D`, downsample, darken, separable blur, additive composite at the end of `R_RenderView`. 1. **Prohibitively slow on a 2001 GPU:** quicksilver R9000 Pro 66.95 to 25.50 fps demo1 1024 (-62%), below the ~40 fps G4 tolerance; the per-frame fullscreen copy plus sample passes are fillrate murder on a 1999-2005 part. 2. **Visually broken on GMA 950/Lion:** first cut left a black box in the corner plus a heavy additive wash; a "restore the scene from the captured texture" blit brought the 3D scene back black, because `R_LoadPic(..., it_pic, ...)` resizes and repacks a large (1024^2) pic texture so the capture region overflows the real texture and the copy silently stays empty. Shipped **disabled** (`gl_bloom 0` everywhere), code kept in-tree. Lessons: (a) a fullscreen post-process is the wrong shape for the PPC fillrate budget; (b) never use `R_LoadPic`/`it_pic` as a render target. **2026-08-23 (#33): (b) fixed, (a) stands.** The 256x256 cap was `R_Upload32` (`r_image.c`), which clamps ANY upload, silently shrinking the screen-res capture texture while `r_bloom.c` used uncapped dimensions for `glCopyTexSubImage2D`. Redone as two fixed manual texnums (`TEXNUM_BLOOMSCREEN`/`TEXNUM_BLOOMEFFECT`, `header/local.h`) created via `qglTexImage2D`, bypassing `R_LoadPic`; this engine never calls `glGenTextures`, so a redo must stay in the manual-id space. Verified visually (screenshot.sh, gl_bloom forced on, mini-intel): correct scene with visible bloom. Cost confirmed: GMA 950/Lion 94.0 to 53.85 fps (**-43%**, exploratory bench, not in results.csv, see `bench.sh`'s `BENCH_CSV`). Inherent to a full-resolution `glCopyTexSubImage2D` in GL1 with no FBO; the capture cannot be made sub-resolution. Still disabled everywhere; G5/imac-2019/Apple Silicon headroom was untested then (see BUGFIXES #33).

## 2026-08-22 MSAA 4x on an R200 G4 falls off a cliff and breaks the floor
quicksilver (733 MHz PPC 7450, Radeon 9000 Pro 64MB, 10.4.11), demo1 1024x768, FULLSCREEN, 3 runs each, `benchmarks/results.csv` 2026-08-22:
    gl_msaa_samples 0    66.15 fps     gl_msaa_samples 2    57.15 fps   shipped, -13.6%     gl_msaa_samples 4    31.40 fps   -52.5%, under the 40 fps G4 floor
Shipped 2x is the right trade; 4x puts a G4 below its playability floor. The 2x to 4x step costs nearly three times the 0x to 2x step, which looks like the R200 leaving a fast resolve path rather than linear sample scaling. Do not raise R200-class machines to 4x. The G5's RV350 is a different chip and not covered. The mode is load-bearing: quake3 measured six settings free on a G3 WINDOWED, then -9.7% fullscreen on the same machine, so a windowed figure ranks settings but does not say where a floor breaks. These are fullscreen: `bench.sh` defaults to `VID_FS=1`/`VID_DFS=0` and passes both explicitly (`bench.sh:149-150`, `:289`), so a leftover `config.cfg` cannot change the mode. Only `imac-g5` deviates (native-resolution capture path, or windowed with `G5_WINDOWED=1`); quicksilver is neither.

## 2026-08-22 A staleness gate caught its bug and refused every good build (#17)
`build-fat.sh` fused an arm64 slice built three hours before the source of the other five, printed "fusing SIX", exited 0. The content-hash gate added to stop that was tested only against a reproduction of the stale slice, passed, shipped, then refused a fully current build twice for two unrelated reasons: the staged arm64 dir never received its `SOURCE-STAMP`, and `build-arm64.sh` computed its stamp while its temporary Makefile edit was applied, recording a tree state the EXIT trap reverted moments later. Commits `ea922696`, `0b526e06`, `cabeae7e`. Lesson: a check that REFUSES bad input must be proved to PASS good input; the passing direction is the one that gets skipped, and a gate that blocks legitimate work gets switched off. Corollaries: a driver that mutates the tree to build must compute its stamp BEFORE the mutation (checked against where the trap fires, not where the write sits); an output dir inside the source tree must be excluded from the hash.

## 2026-08-22 `strings` showed three of six slices with no architecture string
Verifying that each slice of the fused `baseq2/game.so` self-identifies, the PowerPC slices came back empty while `amd64`, `i386`, `arm64` read fine. `strings` defaults to a 4-character minimum and `ppc` is three: use `-n 3`. *A verification tool returning nothing is not evidence the property is absent.* Dangerous because it is a false NEGATIVE in exactly the check `docs/adr/0006` exists to make people run, and plausible: the three PowerPC slices genuinely did report `unknown` before `0647fbcb`.
