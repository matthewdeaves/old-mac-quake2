# GeForce 9400 projected shadows

Snow Leopard, native 1920x1080 fullscreen, requested MSAA2, bloom enabled
with partial restoration, darken4 and size256. Both modes use gl_shadows1
and combined depth/stencil clear1. Only gl_stencilshadow changes.

| Demo | Blobs A | Projected B | Projected B | Blobs A |
| --- | --- | --- | --- | --- |
| demo2 | 48.50 | 44.75 | 44.15 | 48.60 |
| demo1 | 49.80 | 45.15 | not run | not run |

Each leg contains three runs through bench.sh. Warm values are the mean of
runs 2 and 3, named median_fps in the CSV. Keep projected shadows as a visual
upgrade; this costs roughly four FPS in demo2, it does not increase speed.
Readbacks confirm requested settings and eight stencil bits. Actual MSAA sample
count was not separately queried. Inspected frame03 and frame07 show the
monster-shaped shadows, intact geometry and bloom. Full image equality is not
expected because the shadow appearance intentionally changes.

These comparisons used the verified RC1 fat renderer beside the unchanged old
installed engine. Hashes and source stamp identify that runtime. Checkout labels
changed during the final leg when the default-selection code was committed;
the timed renderer did not change. The default-selection change is 09e5ff44.
Normal renderer and config hashes match their backups after the experiment.

The new default requests -1 only in the generic x86_64 profile, resolves to 1
for GeForce 9400 and 0 for unmeasured GPUs, and preserves explicit 0/1 values.
Production-function unit tests cover measured/unmeasured GPU strings, mixed
explicit/automatic options and preservation on restart. ASan/UBSan, repository
invariants and static analysis of r_main.c pass.

System mute commands were sent, but this host reports missing audio settings.
Both screenshot.sh and bench.sh explicitly disable sound with s_initsound0.
The extra `volume 0` line in these archived experiment configs is not the
engine's sound-volume control, which is s_volume. Silence does not depend on
that line. Profiling runs, if present in their own subdirectory, are instrumented
and are not accepted FPS measurements.

## Profile, separate from timing

The unprivileged sampler could not attach; a separate run with sudo sample
succeeded. Of 3934 main-thread samples, 3099 were under CGLFlushDrawable and
3090 reached mach_msg_trap through the driver. This measures where the CPU
waited, not GPU utilization or a specific GPU operation's cost. It points to
GPU/submission work as the next investigation rather than tiny CPU loops.
Do not use the instrumented run's FPS as a baseline. The profile used the same
cached RC1 renderer, not the newly built RC2 default-selection code.

The subsequent RC2 build includes all six CPU slices with source stamp
e7f61bc37222999b95b8e4b67bc8743cb5c4d897170134aec40030c8f82fafd7.
The DMG was packaged on Tiger, bundle signatures checked, and runtime bytes
inside the image matched the build. Its SHA256 is
c6bb82924ea8369e81de03ef57cafa0f637f6807e4664c81645d5a3fb3746ac5.
Installed acceptance is recorded separately. The G3 was not accessed or updated.
