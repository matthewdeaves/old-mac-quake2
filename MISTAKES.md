# Mistakes log: settled negatives, do not re-chase

Append-only register of things that were tried and were wrong, harmful or
misjudged. Each entry exists so a future round does not re-litigate it on
incomplete information. **Read this before lighting up an idea that smells
"easy / load-time only / zero risk"**, that smell test has failed here four
times, and three of those took a machine down.

Newest first within each file. Where a mechanism became a standing decision it
lives in `docs/adr/` and the entry is a pointer, not a copy.

Cross-applicable lessons from the sister project are in
`~/quakespasm/MISTAKES.md`, especially benchmark concurrency and SDL framework
dyld install-name quirks.

## Topics (`grep -n '^## ' <file>` for its entries)

- [build-packaging-deploy](docs/mistakes/build-packaging-deploy.md): gates that must pass good input, false-negative verifiers, one-byte DMG flip, `-faltivec` un-stamping, create-dmg rejected.
- [testing-build-scripts](docs/mistakes/testing-build-scripts.md): stubbed builds that still `rm -rf`, backticks in `git commit -m`, `git add -A` sweeping sibling files, checks that pass on unreadable input.
- [video-init-fullscreen](docs/mistakes/video-init-fullscreen.md): `vid_restart` crashes on the G3, config-after-`CL_Init`, iMac G5 R300 fullscreen hang, `killall -KILL` black screen.
- [renderer-features](docs/mistakes/renderer-features.md): bloom, MSAA, stencil shadows, caustics, glass lighting, decals, multitexture state, texture formats, framebuffer experiments.
- [dynamic-lights-geforce2](docs/mistakes/dynamic-lights-geforce2.md): three failed attempts to afford `gl_dynamic 1` on the GeForce2 MX, CPU-bound, AltiVec net-negative.
- [altivec](docs/mistakes/altivec.md): `R_LerpVerts` warped models while the bench read +4.3%.
- [assessed-not-worth-doing](docs/mistakes/assessed-not-worth-doing.md): analyses that concluded "no" (`frsqrte`, sound mixer, group-draw port, MSAA 4x on R200).
- [watch-items](docs/mistakes/watch-items.md): risks flagged but not yet observed.
