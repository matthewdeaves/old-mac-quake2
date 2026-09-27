# Tiger QEMU visual checks

Builds and shared fleet tooling are owned by `old-mac-build-host`.

```sh
scripts/vm-frame-check.sh /tmp/quake2-gameplay.png
```

This host framebuffer smoke check claims `qemu-tiger3d`, refuses an overlapping
game, plays `demo1.dm2` at 1024x768, captures through QEMU's monitor, and asks
the engine to quit normally. The SSH session remains connected while the Tiger
GUI process runs. Inspect the resulting image for rendering faults.

This is separate from `check-frames.sh`: a wall-clock host capture is not a
replacement for its deterministic guest-frame comparisons. Guest screenshot
readback remains tracked in matthewdeaves/qemu#7 and this repo's #97. Do not
replace the reference image set with black guest screenshots or claim that an
FPS pass proves visual correctness.

Validated on 2026-09-27: the helper captured visible `demo1.dm2` gameplay at
1024x768, including world textures, viewmodel and HUD, then logged a normal
engine and SDL audio shutdown. The captured frame was visually inspected.
