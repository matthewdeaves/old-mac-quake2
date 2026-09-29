# Bugfixes

Search by ticket or date; entries are newest first.
Archive: `docs/archive/`.
Dates added to undated accounts identify their recorded evidence or first Git record, not a newly inferred incident date.

## #45 `build-fat.sh` lion leg shipped a v2.11.0 RC that segfaulted on real Lion
The imac-2019 fast path (#41) used Sequoia clang/ld64, which emits `LC_MAIN`; 2011 Lion's dyld only understands `LC_UNIXTHREAD`, a gap no compiler flag closes. Confirmed with `otool -l` and a direct exec on mini-intel (exit 139, zero stdout).
Fix: the lion leg builds on the pinned `BUILD_HOST` (real Xcode 4.6.x ld) by default; the imac-2019 path is opt-in (`QUAKE2_USE_IMAC2019_LION=1`) with a warning to verify `LC_UNIXTHREAD`.

## #47 A prior force-quit or crash hung the next launch forever
No window, no qconsole.log, no crash report. AppKit window-state restoration raised a modal `-[NSAlert runModal]` ("reopen windows?") via `-[NSPersistentUIManager promptToIgnorePersistentState]` before `applicationDidFinishLaunching:`; `sample` showed the main thread parked there. WatchLink ruled out (`+set watch_host ""` hung identically).
Fix: `NSQuitAlwaysKeepsWindows = false` in `Info.plist` (the real fix) plus `applicationSupportsSecureRestorableState:` returning `NO` in `SDLMain.m` (good practice, does not disable the prompt alone).

## 2026-09-23 Renderer init failure crashed the game (e7226281)
`VID_CheckChanges` fell back to `vid_ref gl`, the only renderer, so nothing reloaded and the next frame called through the freed renderer table: SIGSEGV in `SCR_UpdateScreen` plus a macOS crash alert (imac-2019, forced scene-resolve failure, v2.13.0).
Now `Com_Error("Couldn't start the OpenGL renderer; see qconsole.log.")`. Same forced failure: exit status 1, no crash report.

## 2026-09-23 Fresh installs leaked the DMG mount on Panther (b57b242b)
Panther's hdiutil detaches only by device; `deploy-dmg.sh`'s fresh-install path detached by mount path, so 10.3 kept the image attached.
Now retries by path, forces, then detaches the whole-disk device, as `update-dmg.sh` already did (#77). Proved on the G3 under 10.3.9: path detach failed, the helper released the image. quake3 found the same bug.

## #85 Parallel DMG updates could silently skip a host (9a387c0a)
`update-dmg.sh` attached `dist/<dmg>` on the orchestration Mac to verify; concurrent attaches of one image race in hdiutil ("Resource busy", 1 in 12 with four parallel `--preflight`). In the v2.13.0 rollout that aborted a g5-tiger update and the chained smoke tested the old install (caught by md5).
Fix: each run mounts a private APFS clone, byte-compared to the original first. 20 of 20 parallel preflights passed, no leftover mounts.
`update-dmg.sh workstation` now installs locally and keeps hand-added `autoexec-controls.cfg` lines.

## #83 PowerPC Macs at Thousands of colors could not launch (cf3d518a)
The ppc member of the bundled SDL 1.2.15 framework quit ~2 s after launch with "Couldn't init SDL video: Unsupported display mode" at Thousands of colors (matthewdeaves/SDL#5 reproduced on the G3, 10.3.9).
Fix: replace only that member with release asset `retro/panther-ppc-sdl5-fix` (d298f453), sha256 `07cc046e…aac554401`, via `lipo -replace ppc` on a Lion mini. New ppc md5 `5f8cb597…` equals the asset.
i386/x86_64/arm64 members byte-identical; 10.3 floor and install name unchanged; engine not rebuilt.

## #69 Redundant framebuffer work on measured GPUs (dff140f3)
Radeon 9200 cleared depth and stencil separately: opt-in `gl_clear_combined` issues them together (same depth range, z-trick phases, polygon offset; recorded GL-call tests cover all 64 state combos). mini-G4 demo1 1024x768 MSAA2 + projected shadows 40.60 to 55.70 fps (A/B/B/A), demo2 40.40 to 55.60.
Bloom restored the whole captured scene though its passes only touched the bottom-left corner: opt-in `gl_bloom_fastrestore` restores that corner for full views (original path kept for reduced/offset views).
GeForce 9400 demo1 1920x1080 bloom+MSAA2 about 42.7 to 49.9 fps, demo2 42.00 to 48.65. Captures match apart from small sampling differences; temporary renderer swaps, not the final DMG.

## 2026-09-22 Current Apple lipo omitted valid PowerPC slices (7e58b5fb)
The orchestration Mac's lipo reports thin PPC binaries as `big-endian-mach-o` and rejects PPC members of a valid fat binary, so the subtype check refused a correctly stamped G4 build.
Build and package checks now read numeric CPU type/subtype via otool (tests: six engine slices, generic PPC, malformed headers, tool failures; real G4 build passed all four subtype checks).
Native arm64 framework assembly uses LLVM lipo when Apple's cannot handle the PPC member; the arch list is verified via otool.

## 2026-09-22 Linux CI could not exercise occupied-install rollback (93ae99d7)
The installer fixture ran on Ubuntu but used Mac-only `md5`, `ditto` and BSD `stat` options. Helper now uses GNU equivalents on Linux, native Mac ops on the fleet; digest reads and device queries reject failed or malformed output.
Update and rollback fixtures pass on macOS and Linux. ShellCheck failure on comma-containing linker flags fixed by quoting array elements (compiler arguments unchanged).

## #33 Fixed-function bloom turned the Apple Silicon fullscreen image black (05abbc7f)
sdl12-compat renders the SDL 1.2 surface through an internal multisample framebuffer and wraps `glCopyTexSubImage2D`/`glReadPixels` to resolve it; QGL loaded those from OpenGL before SDL created the context, so bloom copied the unresolved framebuffer.
Fix: after `R_SetMode` creates the context, detect sdl12-compat by runtime symbol and replace both readbacks with `SDL_GL_GetProcAddress` addresses (real SDL 1.2 keeps its bindings).
Passed on Apple M5 and Panther G5/Radeon 9600; Radeon Pro 580X rendered with zero GL errors; GMA 950 untested (headless captures invalid). M5 bloom 264.55 fps warm median at 1920x1080 4x MSAA, so arm64 enables it with `gl_bloom_darken 1`; G3/G4 stay off on cost.
Evidence: `benchmarks/experiments/2026-09-12-bloom-readback/`.

## #67 Occupied installs had no rollback-safe update path (8096356b)
The fresh deployer refused an existing `/Applications/Quake2`, leaving no bounded way to install a validated successor.
`deploy-dmg.sh --update` preflights the exact DMG, copies the whole install to a same-volume stage, verifies preserved data and runtime, and promotes only after all pre-publish gates pass; success keeps the old install under a unique rollback name.
A failed post-publish gate restores the original path and keeps the rejected candidate. Fixtures cover refusal, automatic restore, update and explicit restore.

## #33 DMG with an arm64 executable shipped without SDL2, then pruned the last tested candidate (c96a9875)
A config-only package took the six-slice executable from a tested DMG but omitted `libSDL2-2.0.0.dylib`; `make-dmg.sh` only warned, and after verification it pruned every older candidate (also breaks #67 rollback).
Missing SDL2 is now fatal whenever arm64 is present, and older candidates are kept for explicit post-acceptance cleanup. The rejected image stayed under `/private/tmp`, never deployed.

## #33 imac-2019 bloom cost -78% and drew nothing (422fb5e9)
demo1 1920x1080 real hardware: 530.6 to 115.35 fps with zero visible pixels. `r_bloom.c` overbright compensation (e9a30c3a) divides the clamped 8-bit value by `gl_overbrightbits` before the `v0^(darken+1)` self-multiply, so at `gl_overbrightbits 4`, darken 4 a saturated pixel is `(0.25)^5`, 32x dimmer than g5-dual's `(0.5)^5`. ImageMagick RMSE off-vs-on 0.0000-0.0003 (noise floor).
Fix: `gl_bloom_darken 1` in `autoexec-imac-2019.cfg`: RMSE 0.018-0.044, same cost (115.35 vs 115.20 fps), since the fullscreen capture/composite is the cost, not the darken passes. g5-dual `darken 4` untouched.

## #56 imac-2019 g5 build: `Com_Printf` called `Con_Print(NULL)`, SIGSEGV in `S_Init` (7f629de1)
`-S` diff, `-mcpu=970` vs `-mcpu=7400`, GCC14: at `-O2/-O3` 970 hoists `li r3,0` (setup for a later `Sys_ConsoleOutput(NULL)`) above the branch that falls through to `Con_Print(msg)`, so it runs with `r3 == 0`; 7400 keeps `msg` in a callee-saved register. Third file hit by this GCC14 register-allocation class (`filesystem.c` #53, `SDLMain.m`).
Fix: `clientserver.c` added to `ppc-cc-wrapper-imac2019.sh`'s per-file `-O0` list. Real g5-tiger: crash gone, engine reaches `VID_LoadRefresh`/`ref_gl.so`, then a different crash (split to a new issue).

## #55 IP bans did not survive a server restart (396dcf26)
`sv addip`/`sv writeip` write `listip.cfg` (`game/g_svcmds.c`) but nothing execs it on startup; same shape as old-mac-half-life-1#31.
Fix: `server.cfg` execs `listip.cfg` unconditionally (a harmless "couldn't exec" before the file exists, per `Cmd_Exec_f`). Documented in `server/README.md`.

## #44 `getaddrinfo()` on the main thread blocked first launch on Wi-Fi (671db998)
imac-2019: app runs, no window, ignores SIGTERM. `SV_InitGame` (`sv_init.c:388`) resolves the dead id master IP on every server start (including the attract-loop server), and `NET_StringToSockaddr` (`network.c:411`) called plain `getaddrinfo()` even for a literal IP, which can block indefinitely on Wi-Fi with an unreachable target.
Fix: try `AI_NUMERICHOST` first (never touches the network), real lookup only for a hostname. Hits any Wi-Fi fleet machine.

## #44 Manual drag-and-drop installs never cleared quarantine (2bb6d8d9)
Unlike the `deploy-dmg.sh` SSH path, a Safari-downloaded install never ran the quarantine-clearing step. `scripts/make-dmg.sh` now ships `Fix and Install.command` in the DMG, which runs `clear-launch-quarantine.sh` before first launch.

## #43 `deploy.sh` had no `TARGET` case for the five G5-tower aliases (2026-08-29, 0b5456af)
`g5-panther`/`g5-tiger`/`g5-desktop`/`quad-tiger`/`quad-leopard` never got game data: launch "opens then quits", `baseq2/` held only `game.so`. `deploy-dmg.sh` only preserves existing data and the aliases (added build-host#30) were never wired into `deploy.sh`; not the engine or the #42 floor fix.
Added the five TARGET cases. Verified on g5-panther (10.3.9): real GL render, full demo, then a fullscreen bench point (153.8 fps at 1680x1050, desktop-capture, R300-safe).

## #35 Double-click launch spun at 100% CPU on Intel, no window (c1cefca1)
imac-2019, mini-intel, mini-intel2. SDLMain.m chdirs to the bundle parent only when `gFinderLaunch` is set, which SDL 1.2 sets only for a `-psn` argv that LaunchServices stopped passing ~10.9. So `dlopen("./ref_gl.so")` in `VID_LoadRefresh` failed silently and every renderer export stayed NULL.
Cause: the arm64-only `OSX_ChdirToBundleParent()` guard was never extended to x86_64/i386. Fix in `yquake2/src/backends/unix/main.c`. PowerPC unaffected (Panther/Tiger still pass `-psn`; 10.3/10.4 SDKs cannot compile `_NSGetExecutablePath`).
mini-sl "cannot create an OpenGL pixel format" (#29) was this same bug (NULL renderer table before pixel-format creation), fixed by the same commit.

## #35 Release DMG `ditto` copy preserved `com.apple.quarantine` (07bdd420)
The browser-downloaded DMG's quarantine flag was preserved into the installed bundle, so Gatekeeper blocked or warned on double-click (also #34).
Fix: `scripts/clear-launch-quarantine.sh` (canonical from `old-mac-build-host`) strips it and force-re-registers with `lsregister`, run in `deploy-dmg.sh`'s remote install right after the byte-verified copy.

## #37 quad-tiger could not deploy: `hdiutil attach` fails `0xE00002C9` (892d34e2)
Kext-layer fault on that machine for every DMG (diagnosed at `old-mac-build-host#41`; survives reboot and power cycle).
`deploy-dmg.sh` now falls back to mounting on a working host and rsyncing the extracted contents, triggered only on that hdiutil exit path (every other host unchanged).

## #38 `smoke-dmg.sh` deleted `qconsole.log` before each launch (34ce29d4)
A run that crashed before the engine flushed its log left nothing for the final `scp` ("no qconsole.log") and no prior transcript. Found first in halflife's identical bug (ADR 0018).
Fix: rotate to `qconsole.prev.log` instead of deleting.

## #28 `deploy-dmg.sh` never cleared a stale `baseq2/autoexec.cfg` (45ca55f0)
Unlike `deploy.sh`, a machine that once autoexec'd a debug/bench cfg kept re-applying it after every fresh DMG install ("launches but wrong", no code change). Folded into #35's launch-reliability sweep.
Fix: clear it in the remote install step, matching `deploy.sh`.

## #33 Bloom rendered into the `R_LoadPic`/`it_pic` 2D pic cache (d85a6281)
The UI pic-cache target is the wrong texture path for a full-screen post-process (right only by accident).
Fix: dedicated `qglTexImage2D` render targets for bloom. Bloom stays off on weak GPUs (GMA950 measured -43%): a tier decision, not this bug.

## #23 Build-host lock released on process identity alone (12997f86)
A sibling session's build could drop another session's live claim on the same Intel mini.
Fix: claim with a nonce (`build-fat.sh`/`build.sh`/`pick-build-host.sh`) so a release only succeeds against the claim that made it.
