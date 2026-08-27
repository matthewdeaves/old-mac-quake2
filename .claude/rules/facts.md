## Facts

- **Six slices, graded by CPU subtype alone.** `ppc750` (G3, min 10.3),
  `ppc7400` (all G4s, min 10.3), `ppc970` (G5, min **10.5**, a real floor),
  `x86_64` (min 10.6), `i386` (min 10.4, never tested on hardware), `arm64`
  (min 11.0, optional: without it the fat is five). The OS plays no part in
  dyld's choice, so a machine gets its slice whether or not it can run it.
  `docs/adr/0001`, `0014`, `0015`
- **`-faltivec` silently defeats `-mcpu=7400`'s cpusubtype stamping**, and a
  generic `ppc (ALL)` member in the fat makes the binary refuse to exec on a G3
  under Tiger or Leopard while Panther accepts it. `build.sh` asserts and
  re-stamps all four artifacts after every PPC build. **Never remove that
  block.** `file` printing `ppc_650` for subtype 9 is a tool quirk; trust
  `lipo`. `docs/adr/0001`
- **The engine is pinned at yquake2 `QUAKE2_5_11`, commit `033550cd`, and that
  means SDL 1.2.** This tree has **ONE renderer**, `src/refresh/` building
  `ref_gl.so`. There is no gl1/gl3 split and no renderer-selection cvar; that is
  upstream only. Any doc claiming otherwise is describing upstream, not this
  tree. `docs/adr/0002`
- **The `arm64` slice is the odd one out twice.** It builds at `-O2` where every
  other slice is `-O3` (`build-arm64.sh:138`), and it is the only slice whose
  `SDL.framework` member is **sdl12-compat**, which `dlopen`s the bundled
  `libSDL2-2.0.0.dylib` at runtime. It still links the same
  `@executable_path/SDL.framework/...` install name as the other five, and it
  does **not** link SDL2 directly. `docs/adr/0014`, `0015`
- **Five slices cross-compile on an Intel Lion mini** (`mini-intel` or
  `mini-intel2`, interchangeable); `arm64` cannot, and is built on the
  orchestration Mac by `scripts/build-arm64.sh`. Ask
  `scripts/pick-build-host.sh`, never hardcode: the claim is a lock ON the
  host, so it sees builds other repos and agents started. `docs/adr/0005`
- **Never run two PPC builds on the same mini.** They share one `-arch ppc`
  object tree and race the `.o` files into the wrong CPU-subtype stamp. Two
  builds on different minis are the point of the second box. `docs/adr/0005`
- **Build the release DMG on a Tiger G4, never Lion and never the G3.** Lion's
  `hdiutil` cannot write a Panther-mountable image and no flag fixes it; the
  1999 G3 once flipped a byte and shipped an illegal-instruction crash to every
  G4. `docs/adr/0005`
- **Never trust "done" or exit 0.** `hdiutil verify` is not a content check.
  Verify the property on the artifact (`lipo -archs`, `otool -L`, `otool -h`),
  and md5 the bytes at the last hop the user runs. PPC builds are **not**
  byte-reproducible (~138 bytes of metadata), so only compare artifacts from the
  same run. `docs/adr/0006`
- **Bundle config is three layers applied BEFORE `CL_Init`/`VID_Init`** (shared
  controls, per-arch baseline picked at compile time, per-machine overlay picked
  by `hw.model`). Applying it later escalates into a refresh-DLL reload that
  hard-crashes the Rage 128 G3. Cfgs use `set CVAR VALUE` and ship
  comment-stripped. `docs/adr/0007`
- **iMac G5 hazard: the Radeon 9600 Leopard driver hard-hangs the whole OS on a
  non-native fullscreen mode SWITCH**, grey screen, no SSH, physical power
  button only. Three guards are in place (`vid_desktopfullscreen`,
  `GLimp_ForceDesktopFullscreen()`, `bench.sh` refusing). **Never bypass them or
  trigger a remote non-native mode switch on the G5.** `docs/adr/0008`
- **A smoke test is a demo run that auto-exits.** Never `+map`, which grabs the
  display forever, and never an engine-load-only check. A clean demo does not
  clear a *gameplay* crash: also start a new game, on **base1**. Always
  `killall -TERM` before `-KILL`. `docs/adr/0009`
- **A green check does not mean the picture is right.** `smoke-dmg.sh` asserts an
  fps line exists, `bench.sh` measures speed, `tests/test-repo.sh` reads shell
  text. Only `scripts/check-frames.sh` looks at an image. It matters because a
  render bug can read as a WIN: AltiVec `R_LerpVerts` warped every alias model
  on mini-g4 and the bench reported **+4.3% fps**, because the broken maths was
  cheaper than the correct maths (`MISTAKES.md`, commit `55bfeb8`, reverted).
  Frames are bit-identical across runs of one binary, so the noise floor is
  zero. References live in `tests/frames/`, NOT `docs/screenshots/`, which is a
  curated gallery that deletes frames for being ugly. Issue #26.
- **Playability floors: G3 ≥ 20 fps, G4 ≥ ~40 fps** (was 60; the user preference
  is visuals over framerate). **A floor is the raw bench number** (`bench.sh`
  runs vsync off), not what a player sees with vsync on — settled by the user,
  `old-mac-build-host#22`, 2026-08-23. Above the floor, prefer a visual feature to
  framerate nobody needs. `docs/adr/0009`
- **Every per-machine default is an A/B on that machine**, never inferred from
  GPU class. `docs/adr/0010`
- **We ship code and generated art, never game content.** `docs/adr/0012`
- **`scripts/source-stamp.sh` is NOT ours to edit.** It is canonical in
  `old-mac-build-host`, byte-identical across five repos, and a drift check
  enforces that. It takes the exclude list as an argument and returns 2 without
  one. This repo's list lives in `scripts/source-stamp-excludes.sh`; change
  that, never the shared file. Both get sourced together, and all four call
  sites pass `"$SOURCE_STAMP_EXCLUDES"` (`build.sh:199`, `:257`,
  `build-fat.sh:140`, `build-arm64.sh:140`). Issue #20.
