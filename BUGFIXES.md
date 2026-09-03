# Bug fixes

Running log of real bugs found and fixed in this repo. Not a changelog of every
commit — see `git log` for that. One entry per bug: symptom, root cause, fix
commit.

## 2026-09-02

- **`getaddrinfo()` on the main thread blocked the first launch on Wi-Fi,
  before any frame ever drew.** Symptom (imac-2019, user-reported):
  app launches, process runs, no game window, unresponsive to SIGTERM.
  Root cause: `SV_InitGame` (`sv_init.c:388`) resolves the hardcoded dead
  id Software master server IP on every server start, including the
  automatic attract-loop server at launch — unconditional, no timeout.
  `NET_StringToSockaddr` (`network.c:411`) called plain `getaddrinfo()`
  even for that literal IP; on macOS over Wi-Fi with an unreachable
  target this can block indefinitely. Fix: try `AI_NUMERICHOST` first
  (never touches the network for a literal IP), fall back to a real
  lookup only for an actual hostname. Not imac-2019-specific — any fleet
  machine on Wi-Fi hits this. Refs #44.
- **Manual (Safari-downloaded, drag-and-drop) installs never ran the
  quarantine-clearing step, unlike the `deploy-dmg.sh` SSH path.**
  `scripts/make-dmg.sh` now ships a `Fix and Install.command` in the DMG
  that runs the existing `clear-launch-quarantine.sh` before first
  launch. Refs #44.
- **`build-fat.sh`'s lion leg shipped a v2.11.0 release candidate that
  segfaulted instantly on real Lion hardware.** Root cause: the leg's
  imac-2019 fast path (issue #41) used imac-2019's Sequoia clang/ld64,
  which emits `LC_MAIN`; real 2011 Lion's dyld only understands
  `LC_UNIXTHREAD`, a linker-generation gap no compiler flag closes.
  Confirmed via `otool -l` and a direct exec on mini-intel (exit 139,
  zero stdout, before any of our code runs). Fix: the lion leg now
  always builds on the pinned `BUILD_HOST` (real Xcode 4.6.x ld) by
  default; the imac-2019 speedup is opt-in
  (`QUAKE2_USE_IMAC2019_LION=1`) and comes with a warning to verify
  `LC_UNIXTHREAD` before shipping. Refs #45.
- **A prior force-quit or crash could hang the *next* launch forever**,
  no window, no qconsole.log, no crash report. Root cause: AppKit's
  window-state restoration puts up a modal `-[NSAlert runModal]`
  ("reopen windows?") via `-[NSPersistentUIManager
  promptToIgnorePersistentState]` *before*
  `applicationDidFinishLaunching:` ever runs, and nothing was there to
  dismiss it. Confirmed via `sample` (gdb couldn't parse the modern
  toolchain's Mach-O to backtrace it) — main thread parked in exactly
  that call chain. Ruled out WatchLink directly (`+set watch_host ""`
  reproduced the identical hang). Fix: `NSQuitAlwaysKeepsWindows = false`
  in `Info.plist` (the actual fix) plus
  `applicationSupportsSecureRestorableState:` returning `NO` in
  `SDLMain.m` (correct practice, doesn't by itself disable the prompt).
  Refs #47.

## 2026-08-29

- **`deploy.sh` had no `TARGET` case for the five G5-tower aliases
  (`g5-panther`/`g5-tiger`/`g5-desktop`/`quad-tiger`/`quad-leopard`), so
  game data was never provisioned on any of them.** Symptom: double-click
  launch on g5-panther "opens then quits, no errors." Root cause was not
  the engine or the #42 floor fix — `~/Desktop/quake2/baseq2/` had only
  `game.so`, no paks, because `deploy-dmg.sh` only preserves existing game
  data and `deploy.sh` (the script that actually fetches it) didn't know
  these aliases existed; they were added to the bench fleet later
  (build-host#30) and never wired into game-data provisioning. Fixed:
  added the five TARGET cases. Verified end to end on g5-panther, true
  Panther 10.3.9 — real GL render, full demo playback, then a real
  fullscreen bench point (153.8 fps @ 1680x1050, desktop-capture,
  R300-safe). #43

## 2026-08-28

- **Double-click launch silently spun at 100% CPU on Intel (imac-2019,
  mini-intel, mini-intel2), no window ever created.** SDLMain.m's own
  chdir-to-bundle-parent only fires when `gFinderLaunch` is set, which SDL 1.2
  sets only on an `argv[1]` starting `-psn` — the process-serial-number arg
  LaunchServices stopped passing around 10.9. So a modern Finder/`open` launch
  never chdirs, `VID_LoadRefresh`'s basedir `.` resolves against whatever cwd
  LaunchServices handed the process, `dlopen("./ref_gl.so", ...)` fails
  silently, and every renderer export stays NULL. Root cause: the existing
  arm64-only `OSX_ChdirToBundleParent()` guard (added for sdl12-compat, which
  skips SDLMain.m's Cocoa entry point) was never extended to x86_64/i386, which
  hit the identical `gFinderLaunch` gap for a different reason. PowerPC is
  unaffected — Panther/Tiger LaunchServices still passes `-psn`, and the
  10.3/10.4 SDKs can't compile the `_NSGetExecutablePath` call this guard uses
  anyway. Fix: `yquake2/src/backends/unix/main.c`, commit `c1cefca1`. Refs #35.

- **A real release DMG carries `com.apple.quarantine` from the browser
  download, and `deploy-dmg.sh`'s `ditto` copy preserved it into the installed
  bundle** — Gatekeeper then blocks or warns on the human's double-click.
  Fix: `scripts/clear-launch-quarantine.sh` (canonical from
  `old-mac-build-host`) strips the flag and force-re-registers with
  `lsregister`, wired into `deploy-dmg.sh`'s remote install step right after
  the byte-verified copy. Commit `07bdd420`. Refs #35/#34.

- **quad-tiger cannot deploy at all: `hdiutil attach` fails with `0xE00002C9`
  on every DMG**, a kext-layer fault on that machine (exhaustively diagnosed at
  `old-mac-build-host#41`; survives reboot and cold power-cycle). Fix:
  `deploy-dmg.sh` now falls back to mounting the DMG on a working host and
  rsyncing the extracted contents across, triggered only on hdiutil's specific
  exit path (every other host's install is byte-for-byte unchanged). Commit
  `892d34e2`. Refs #37.

- **`smoke-dmg.sh` deleted `qconsole.log` before every launch as a "clean
  slate"**, so a run that crashed before the engine wrote or flushed its own
  log left nothing to pull back: the `scp` at the end fails with "no
  qconsole.log", and there's no prior transcript to compare against either.
  Cross-port finding from halflife's identical bug (ADR 0018). Fix: rotate to
  `qconsole.prev.log` instead of deleting. Refs #38.

- **The build-host lock was released on process identity alone, so a sibling
  session's build could drop another session's live claim** on the same
  Intel mini. Fix: claim with a nonce (`build-fat.sh`/`build.sh`/
  `pick-build-host.sh`), so a release only succeeds against the claim that
  made it. Commit `12997f86`. Refs #23.

- **`deploy-dmg.sh` never cleared a stale `baseq2/autoexec.cfg` on install,
  unlike `deploy.sh`**, so a machine that had ever had a debug/bench cfg
  autoexec'd kept re-applying it after every fresh DMG install — a "launches
  but wrong" report with no code change to explain it. Fix: clear it in the
  remote install step, matching `deploy.sh`'s existing behaviour. Commit
  `45ca55f0`. Refs #28 (folded into #35's launch-reliability sweep).

- **Bloom rendered into `R_LoadPic`/`it_pic`, the 2D-UI pic-cache render
  target**, the wrong texture path for a full-screen post-process effect —
  correct on some paths by accident, wrong render target in general. Fix:
  dedicated `qglTexImage2D` render targets for bloom instead of borrowing the
  UI pic cache. Commit `d85a6281`. Refs #33. (Bloom itself stays off on weak
  GPUs — GMA950 measured -43% — that's a perf/tier decision, not this bug.)

- **mini-sl "cannot create an OpenGL pixel format" (#29) was the same root
  cause as #35's chdir bug, not a separate GL/driver fault**: the engine spun
  at 100% CPU with a NULL renderer table before ever reaching pixel-format
  creation, which read like a GL failure from the console log alone. Confirmed
  fixed by the same `c1cefca1` chdir fix — no GL-specific change needed.

- **`sv addip`/`sv writeip` saved an IP ban to `listip.cfg`, but nothing ever
  execed that file back in on server startup** (confirmed reading
  `game/g_svcmds.c`, which only writes it) — an IP ban silently stopped
  working the moment the server process restarted, same shape as
  old-mac-half-life-1#31. Fix: `server.cfg` now execs `listip.cfg`
  unconditionally at startup (harmless "couldn't exec" no-op before the file
  exists, confirmed in `common/cmdparser.c`'s `Cmd_Exec_f`). Documented in
  `server/README.md`. Refs #55.

- **imac-2019 g5 build: `Com_Printf` calls `Con_Print(NULL)`, SIGSEGV in
  `S_Init`** (issue #56, split out of #53). Root-caused with a real `-S`
  assembly diff, `-mcpu=970` vs `-mcpu=7400`, same GCC14 toolchain:
  `-mcpu=7400` keeps `msg`'s address (Com_Printf's local
  `char[MAXPRINTMSG]`) alive in a callee-saved register across the whole
  function; `-mcpu=970` at `-O2`/`-O3` instead lets the scheduler hoist
  `li r3,0` -- the argument setup for a LATER, unrelated
  `Sys_ConsoleOutput(NULL)` call -- up above the branch that falls through
  to `Con_Print(msg)`, so it runs with `r3 == 0`. Same GCC14
  register-allocation bug class as `filesystem.c` (#53) and `SDLMain.m`,
  third file it has hit, first one pinned to the exact clobbering
  instruction. Fix: `clientserver.c` added to
  `ppc-cc-wrapper-imac2019.sh`'s per-file `-O0` list. Confirmed on real
  g5-tiger hardware: this crash is gone, engine now gets past `S_Init` into
  `VID_LoadRefresh`/`ref_gl.so` before hitting a DIFFERENT crash -- split
  out as a new issue rather than expanding this one's scope. Refs #56.

- **imac-2019: `gl_bloom` paid its full ~-78% fps cost (530.6 -> 115.35 fps,
  demo1 1920x1080, real hardware) and produced ZERO visible pixels**
  (issue #33). Root cause: `r_bloom.c`'s overbright compensation
  (e9a30c3a) divides the already-clamped 8-bit backbuffer value by
  `gl_overbrightbits` before the darken stage's self-multiply passes
  (`v0^(darken+1)`), so a genuinely bright/saturated pixel is recovered as
  only `1/overbrightbits` before being raised to that power. At
  imac-2019's `gl_overbrightbits 4` (default darken 4, so `v0^5`) that is
  `(0.25)^5` -- 32x dimmer than g5-dual's `overbrightbits 2` case
  (`(0.5)^5`), which is why bloom is confirmed visible there but was
  invisible here. Confirmed with ImageMagick RMSE across the whole demo1
  frame set (off-vs-on: 0.0000-0.0003, noise floor) rather than eyeballed.
  Fix: `gl_bloom_darken 1` for imac-2019 specifically (per-machine
  override, `autoexec-imac-2019.cfg`) restores a real, visible,
  non-overexposed glow (RMSE 0.018-0.044) at the SAME measured cost
  (115.35 vs 115.20 fps) -- the darken pass count isn't what the GPU time
  goes on, the fullscreen capture/composite is. g5-dual's own working
  `darken 4`/`overbrightbits 2` combination is untouched. Refs #33.
