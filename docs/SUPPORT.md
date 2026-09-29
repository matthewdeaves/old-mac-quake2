## Engine facts

- **Six slices, graded by CPU subtype alone.** `ppc750` (G3, min 10.3), `ppc7400` (G4s, min 10.3), `ppc970` (G5, min **10.5**, a real floor), `x86_64` (10.6), `i386` (10.4, never on hardware), `arm64` (11.0, optional). The OS plays no part in dyld's choice. ADR 0001, 0014, 0015
- **Pinned at yquake2 `QUAKE2_5_11` (`033550cd`), SDL 1.2, ONE renderer** (`src/refresh/` builds `ref_gl.so`). No gl1/gl3 split, no renderer cvar; docs saying otherwise describe upstream. ADR 0002
- **arm64 is the odd slice twice**: `-O2` where the rest are `-O3` (`build-arm64.sh:138`), and its `SDL.framework` is sdl12-compat, which `dlopen`s the bundled SDL2. Same `@executable_path/SDL.framework` install name. ADR 0014, 0015
- **Bundle config is three layers applied BEFORE `CL_Init`/`VID_Init`** (shared, per-arch, per-machine overlay by `hw.model`). Applying later triggers a refresh-DLL reload that hard-crashes the Rage 128 G3. Cfgs use `set CVAR VALUE`, comment-stripped. ADR 0007
- **Every per-machine default is an A/B on that machine**, never inferred from GPU class. ADR 0010
- **An `ERR_DROP` looks like a freeze**: the console redraws forever, CPU pegged, SIGTERM ignored, no crash log. Reproduce with `+set logfile 2`, windowed on hazardous machines. ADR 0009
- **A finished timedemo also ignores SIGTERM** (mini-g4, qemu-tiger3d): `q2_stop` escalates TERM to KILL, except on G5 aliases. See `scripts/q2-launch.sh`.
- **A floor is the raw bench number** (vsync off), not what a player sees. Settled, build-host#22. ADR 0009
- **We ship code and generated art, never game content.** ADR 0012
- **A frame regression can read as a fps win** (AltiVec `R_LerpVerts` warped models, +4.3%): look at `check-frames.sh`, not only the number. `grep -n LerpVerts MISTAKES.md docs/mistakes/*.md`
