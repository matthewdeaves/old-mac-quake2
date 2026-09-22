# GeForce 9400 antialiasing quality screen

Snow Leopard, native 1920x1080, demo2. Optimized bloom enabled in both modes,
darken4 and size256. Requested MSAA2 gives 48.3/48.4/48.1 fps, warm 48.25.
Requested MSAA4 gives 30.4/30.4/30.4, warm 30.40. Keep the existing 2x default
for headroom. No new default or engine change came from this test.

The cvar readbacks confirm the requested counts. This runtime does not log the
driver's actual sample count, so do not present these as a separate GL sample
count query. Inspected captures show intact geometry and modest edge changes;
selected frame03 normalized RMSE is 0.00381845. Capture timing is not FPS timing.

The same verified final fat renderer was temporarily installed beside the old
engine in both legs. CSV checkout labels changed only because unrelated evidence
was committed during the experiment; the runtime was not rebuilt or changed.
See source stamp and hashes. Original renderer and normal config were restored.

The host reports missing audio settings and no audio outputs in the earlier
preflight. Both mute commands were sent, benchmarks disabled sound initialization,
and the capture config explicitly set volume0. Do not claim a successful system
mute readback on this host or sound-enabled benchmark coverage.
