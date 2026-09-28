# Assessed and not worth doing

Not failures: analyses that concluded "no" and should not be re-derived. Covers the `frsqrte` backport, an AltiVec sound mixer, yquake2-latest GL1 multitexturing and group-draw cherry-picks, KMQuake2 decals, `demo3.dm2`, and MSAA 4x on R200 G4s (falls off a cliff below the 40 fps floor).

## `frsqrte` `Q_rsqrt_ppc` backport: about 0% framewide
The per-frame render path has only 3 `VectorNormalize` calls (`r_mesh.c`, `r_main.c`, `r_decal.c`), saving roughly 25 ns each, about 75 ns per frame, well under 0.01% of a 16 ms frame. The 26 calls in `cl_effects.c` are bursty particle spawns and the 7 in `pmove.c` run at 10 Hz. Only worth it for parity with the sister project.

## AltiVec 16-bit sound mixer: forecast 1-2% framewide on G4
Only during heavy combat; 0% while quiet, 0% on Intel (different mixer). Not attempted. The real gate would be listening for clipping or phase artifacts, not fps.

## "GL1 multitexturing" from yquake2-latest is a no-op here
5.11 already calls `R_RenderLightmappedPoly` via the SGIS multitex path when available (`r_surf.c:1172-1228`); the newer tree adds a runtime toggle cvar, not new hot-path code.

## Cherry-picking yquake2-latest's group-draw wholesale is a multi-day hand-port
A 2024 multi-file refactor; every cherry-pick conflicts with the `refresh/` to `gl1/` rename and the intermingled client refactor commits. What shipped is our own `r_buffer.c` (`gl_groupdraw`).

## KMQuake2 decals are game-DLL-driven upstream
`R_AddDecal` is called from `g_combat.c`/`p_weapon.c` impact handlers, so a pure renderer port delivers nothing without touching `baseq2/game.so`. This port instead hooks the client temp-entity handlers in `cl_tempentities.c`.

## `demo3.dm2` does not exist in any retail pak
See ADR 0009.

## MSAA 4x on an R200 G4 falls off a cliff and breaks the floor
quicksilver (733 MHz PPC 7450, Radeon 9000 Pro 64MB, 10.4.11), demo1 1024x768, FULLSCREEN, 3 runs each, `benchmarks/results.csv` 2026-08-22:

    gl_msaa_samples 0    66.15 fps
    gl_msaa_samples 2    57.15 fps   shipped, -13.6%
    gl_msaa_samples 4    31.40 fps   -52.5%, under the 40 fps G4 floor

Shipped 2x is the right trade; 4x puts a G4 below its playability floor. The 2x to 4x step costs nearly three times the 0x to 2x step, which looks like the R200 leaving a fast resolve path rather than linear sample scaling. Do not raise R200-class machines to 4x. The G5's RV350 is a different chip and not covered.
The mode is load-bearing: quake3 measured six settings free on a G3 WINDOWED, then -9.7% fullscreen on the same machine, so a windowed figure ranks settings but does not say where a floor breaks. These are fullscreen: `bench.sh` defaults to `VID_FS=1`/`VID_DFS=0` and passes both explicitly (`bench.sh:149-150`, `:289`), so a leftover `config.cfg` cannot change the mode. Only `imac-g5` deviates (native-resolution capture path, or windowed with `G5_WINDOWED=1`); quicksilver is neither.
