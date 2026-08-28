# Bug fixes

Running log of real bugs found and fixed in this repo. Not a changelog of every
commit — see `git log` for that. One entry per bug: symptom, root cause, fix
commit.

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
