# Build, deploy & package — yquake2 PPC port

How the fat universal `Quake2.app` is built, shipped, and packaged into a DMG.
Read this when you touch `scripts/build*.sh`, `deploy*.sh`, `make-dmg.sh`, the
SDL framework, or the cross-build host. Quick rules live in CLAUDE.md.

## yquake2 5.11 build basics

The engine builds three artifacts: `quake2` (client), `q2ded` (dedicated
server, can disable), `ref_gl.so` (GL renderer, loaded at runtime).
**The renderer is a runtime-loaded shared library on Linux/Windows,
but on macOS the build system bundles it into the .app — same end
result, different mechanics from QuakeSpasm.**

Makefile knobs at the top of `yquake2/Makefile` (all default `yes`):
`WITH_CDA`, `WITH_OGG`, `WITH_OPENAL`, `WITH_RETEXTURING`, `WITH_ZIP`,
`WITH_SYSTEMWIDE`. `scripts/build.sh` sed-overrides the first three to
`no` per build (we have no CD, no OGG/OpenAL deps installed on PPC),
leaves `WITH_RETEXTURING=yes` (now satisfied by the vendored
`stb_image.h` — see HD_PACK.md), `WITH_ZIP=yes` (libz ships in Tiger),
and `WITH_SYSTEMWIDE=no`. `OSX_ARCH` defaults to `-arch i386 -arch
x86_64`; we override per target via `OSX_ARCH=` in `scripts/build.sh`.

PPC build flag override pattern (matches QuakeSpasm):
- G3:   `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4:   `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`
- G5:   `-isysroot /Developer/SDKs/MacOSX10.5.sdk   -mmacosx-version-min=10.5   -arch ppc -mcpu=970 -maltivec -mabi=altivec -O3 -DQ2_ARCH_PPC970`
- Lion: `-arch x86_64 -mmacosx-version-min=10.7 -O3`

The `-DQ2_ARCH_PPC970` flag is load-bearing: Apple gcc defines no
`__ppc970__` macro for `-mcpu=970` (only `__VEC__`/`__ALTIVEC__`/`__ppc__`,
same as the G4), so the 970 slice is indistinguishable from the 7400 slice
at compile time. `misc.c` checks `Q2_ARCH_PPC970` FIRST — before the
`__VEC__ → ppc7400` branch — to load the generic-G5 baseline. The 10.5 SDK
is already installed on mini-intel at `/Developer/SDKs/MacOSX10.5.sdk`.

## Expected Tiger/Panther patch class

Based on the QuakeSpasm experience, expect this kind of patch in
yquake2 5.11 (which targets 10.6+):
1. **NSAlertStyle / NSAlert macros** — 10.4 only has `NSCriticalAlertStyle`.
2. **NSString encoding APIs** — `stringWithCString:encoding:` is 10.4+;
   need conditional fallback to `stringWithCString:`. (Q2 may not hit
   this — the SDLMain.m boilerplate is simpler than QuakeSpasm's
   Launcher.nib stack.)
3. **`kCGLCEMPEngine`** — 10.4.8+ only, doesn't exist in 10.3.9 SDK
   headers. Wrap in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`.
4. **gcc-4.0 vs Obj-C 2.0 dot notation** — gcc-4.0 (Panther toolchain)
   doesn't parse dot notation; need `[obj setX:y]` form.
5. **Anything else surfaced by `make` failing** — discover empirically.

The first build attempt on Lion against 10.4u SDK will surface the
full list. **Don't pre-patch speculatively.**

## SDL framework strategy: reuse QuakeSpasm's fat SDL

The fat SDL 1.2 framework at `~/quakespasm/MacOSX/SDL.framework` is
fat (x86_64 + i386 + ppc), and the PPC slice is the Panther-
compatible 10.3.9-SDK build. **Copy it into `~/quake2/MacOSX/` for
Phase A and reuse byte-for-byte.** No need to rebuild SDL; we already
solved that problem.

The Panther slice came from `~/quakespasm/MacOSX/SDL-panther.dylib`
(ppc-only, built against 10.3.9 SDK with `--disable-video-x11
--disable-altivec --disable-cdrom`). Regeneration recipe is in
`~/quakespasm/CLAUDE.md` under "How the fat SDL was built".

**2026-05-31 — added a 4th slice for the iMac G5.** The Panther ppc slice
*runs* on Leopard but its fullscreen path is suspect there, so the
QuakeSpasm project built a dedicated **ppc970 SDL 1.2.15 slice against the
10.5 SDK** (`-mcpu=970`, stamped `ppc970` subtype) and lipo'd it into
`~/quakespasm/MacOSX/SDL.framework`. We copy that 4-slice framework
(x86_64 + i386 + ppc-Panther + ppc970-Leopard) byte-for-byte into
`~/quake2/MacOSX/SDL.framework` — dyld auto-selects the ppc970 slice on
the G5, G3/G4 keep the Panther slice → zero regression. Re-sync with
`rsync -a --delete ~/quakespasm/MacOSX/SDL.framework/ ~/quake2/MacOSX/SDL.framework/`
if QuakeSpasm rebuilds it. (Gotcha QS hit: SDL's build injects
`-force_cpusubtype_ALL`, which stamps a generic `ppc` subtype and collides
with the existing slice — it must be stripped from the generated Makefile
so `-mcpu=970` stamps a real `ppc970`.)

## Multi-tenancy on mini-intel (shared with the QuakeSpasm sister project)

`mini-intel` is the cross-build host for **both** this Q2 port and the
QuakeSpasm sister project at `~/quakespasm/`. The two projects coexist
on the same Lion box by using **separate upload directories** for source
rsync and **workstation-local** build artifacts. Don't conflate them.

| Resource | QuakeSpasm uses | Q2 uses (must) |
|---|---|---|
| Source rsync target on mini-intel | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd on mini-intel | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` (Q2's makefile is at the top level) |
| Local flock for build serialization | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| Local build outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

**Shared (read-only)**: `/Developer/SDKs/MacOSX10.3.9.sdk`,
`/Developer/SDKs/MacOSX10.4u.sdk`, `/usr/bin/gcc-4.0`, `/usr/bin/clang`.
**Never modify** anything under `/Developer/SDKs/` or the system
toolchain — QS depends on the current install and re-installing Xcode
3.2.6 + 2.5 from the vendored DMGs is a multi-hour recovery operation.

**Concurrent builds are safe given the above isolation** — each project
flocks on its own workstation-side lock, rsyncs to its own dir on
mini-intel, and `make -jN` operates in its own dir. The only contention
is CPU/memory on the dual-core Core 2 Duo, which means concurrent
compiles take ~2× wall clock but produce correct binaries. If mini-intel
is already mid-compile for QS when Q2 wants to build, prefer to wait
(serial is faster than 2× concurrent on a 2-core box) — but it's not a
correctness issue.

**Tell-tale of accidental conflation**: if `scripts/build.sh` ends up
rsyncing to `mini-intel:~/` (no project prefix) or to
`mini-intel:quakespasm/`, the Q2 build will overwrite QS source and
break the sister project. `build.sh` hard-codes `mini-intel:quake2/` and
asserts the path is project-local before rsync.

## Don't run PPC builds in parallel (g3 / g4 / g5)

Same race condition as QuakeSpasm: concurrent invocations rsync to the
same path on mini-intel and `make -j2` in the same dir. The .o files
race and the binary ends up stamped with the *other* target's CPU
subtype. Symptom: G3 binary becomes `ppc7400`, Panther loads it, then
crashes during NIB init on a 750. With the G5 slice added the hazard is
worse (three PPC targets now share the same `-arch ppc` .o tree, only
differing by `-mcpu`), so the wrong-subtype stamp is even easier to hit.
`scripts/build.sh` takes a flock to serialize — don't bypass.
`scripts/build-fat.sh` runs g3→g4→g5→lion strictly sequentially for the
same reason. (`build.sh` also `make clean`s before each slice so a stale
`.o` from a different `-mcpu` can't leak into the wrong slice.)

## Deploy is fat-only (no per-target mode)

`scripts/deploy.sh <machine>` ships ONE thing — the universal `Quake2.app`
from `build/q2-fat/`. The previous dual-mode design (per-target flat
layout vs fat .app) had a foot-gun: both modes wrote to the same
`~/Desktop/quake2/` with `rsync --delete`, so running the wrong one
wiped out the .app. Per-target mode is gone. `scripts/build.sh g3|g4|lion`
still exists for fast single-slice iteration during dev, but those slices
only feed `scripts/build-fat.sh` — they don't deploy independently.

Target install layout (`~/Desktop/quake2/`): `Quake2.app` (everything
inside), plus `ref_gl.so` / `q2ded` / `baseq2/game.so` OUTSIDE the bundle
(Q2 resolves those via `basedir=.`), plus the user's `baseq2/pak*.pak`.

## DMG packaging (`scripts/make-dmg.sh`)

Produces `dist/Quake2-OldMac-<ver>.dmg`. The binary is built on Lion
(mini-intel); only the `hdiutil` packaging step runs on a remote Mac.

**Build the DMG on TIGER, not the G3, and not Lion** (empirically tested
2026-05-31 — see MISTAKES.md "DMG byte-flip"):
- **Lion's hdiutil cannot write a Panther-mountable image.** UDZO,
  uncompressed UDRO, and `-layout SPUD` (Apple Partition Map) all report
  "no mountable file systems" on 10.3.9. No flag fixes it.
- **A Tiger-built UDZO mounts on Panther AND everything newer** (old→new
  compat holds; new→old doesn't). Tiger (10.4) is the oldest OS needed for
  `hdiutil`.
- `DMG_HOST` defaults to a reachable Tiger box (`quicksilver`, then
  `mini-g4`). Do NOT use the 1999 Panther G3 — its non-ECC RAM / 25-yr-old
  disk is the flakiest hardware in the fleet and was the source of the
  single-byte corruption.

**`hdiutil verify` is NOT a content check** — it only checks the UDIF
container decompresses to what was stored, not that what was stored matches
the source. So `make-dmg.sh` does **end-to-end content verification**: it
mounts the finished image and md5s `quake2` / `ref_gl.so` / `game.so`
*inside it* against the staged source, retries up to 3×, and FAILS LOUD if
it can't be made byte-identical; it also md5-checks the scp-back. Never
weaken or skip this — a corrupt DMG once shipped an illegal-instruction
crash to every G4.

Implementation gotchas (for editing the verify path):
- Panther's BSD `grep` has no `-o` — parse mount points with `sed` or use
  an explicit `-mountpoint`.
- `ssh host bash -s "$LIST"` word-splits the args — hardcode the file list
  in the remote heredoc rather than passing a space-separated arg.
- Use `md5 file | awk '{print $NF}'` on the Macs (portable Panther→Lion).

## Test the shipped artifact, the way a human installs it

The DMG path diverges from `deploy.sh` (extra `hdiutil` hop) — so test the
actual DMG, not just the build:
- `scripts/deploy-dmg.sh <machine>` — copy the `.dmg` to the Desktop,
  md5-verify it arrived, mount it, `ditto` the `.app` + copy loose libs
  into `~/Desktop/quake2/` (preserving game data), unmount. (Detach
  carefully on the slow G3 disk: loop-retry the detach then `rmdir` the
  empty mountpoint — NEVER `rm -rf` a path that might still be a mounted
  read-only volume.)
- `scripts/smoke-dmg.sh <machine>` — launch the installed copy with the
  PRODUCTION config (NOT `-noarchautoexec`) + a timedemo so it auto-exits;
  confirms world render AND the production resolution. See `docs/BENCH.md`.

Loop per fix: `make-dmg` (verified) → `deploy-dmg` → `smoke-dmg` on
G3/G4/G5 → human starts a new game. Then update the GitHub release and
**download the published asset back and md5-compare it to the verified
source DMG** to close the loop.

## Game data location

Quicksilver bench machine has the canonical game data at
`~/Desktop/Quake 2/` (after the Phase A tidy round). Mirror to other
machines via `deploy.sh` (rsync). Required dirs:
- `baseq2/pak0.pak` (184 MB — main game)
- `baseq2/pak1.pak` (13 MB — 3.20 point release)
- `baseq2/pak2.pak` (45 KB)
- `baseq2/players/` (player model skins)
- `baseq2/video/` (cinematics)
- `ctf/` (Capture the Flag mission pack — pak0 + pak1)
- *(optional)* `rogue/`, `xatrix/` — mission packs (need to source pak files)

## Reuse from QuakeSpasm — do NOT duplicate

- **SSH config** — already in `~/.ssh/config` with legacy crypto (and
  `~/.ssh/id_rsa_tiger`).
- **Cross-build toolchain on mini-intel** — gcc-4.0 + 10.3.9/10.4u/10.5 SDKs.
- **Vendored prereqs/** — Xcode 3.2.6, Xcode 2.5, SDL 1.2.15 sources live in
  `~/quakespasm/prereqs/` (~5 GB). Reference, don't duplicate.
- **host-bin tooling** — `qsreboot.sh` already installed on every bench Mac;
  same reboot-recovery path applies to Q2 crashes.
