# G3 projected shadows

Panther 10.3.9, Rage 128, 1024x768 fullscreen. The driver reports eight stencil
bits. Projected monster shadows are visibly present in `projected.png`; compare
the same scene with `blobs.png`. These images came from the initial thin-renderer
screening. The repeated results here use the final fat renderer, temporarily
installed beside the old engine. Hash records distinguish those components.

With `gl_shadows 1`, `gl_stencilshadow 1`, `gl_clear_combined 1`, `gl_ztrick 0`:
demo1 warm result 28.40 fps, demo2 28.35 fps. Blob control uses stencilshadow 0
and clear_combined 0, reaching 29.50 fps in demo2. Each result is the median of
runs two and three. Audio was disabled by the benchmark and the OS was muted.
These are not sound-enabled gameplay measurements or whole-candidate acceptance.

Keep projected shadows in the G3 profile. Tiger coverage remains pending; the
user requested Panther left ready for manual play. Do not reboot it for tests.
Other texture, fog, decal and lighting settings remain unchanged.

The candidate package reuses the verified fat runtime recorded in
`../candidate-build/`; its later configuration change does not rebuild engine
code. All runtime products contain ppc750, ppc7400, ppc970, i386, x86_64 and arm64.
