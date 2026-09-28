# Tiger QEMU visual checks

Host-side gameplay frame capture on the `qemu-tiger3d` VM: `scripts/vm-frame-check.sh` plays `demo1.dm2` and captures a PNG through QEMU's monitor for eyeballing. It complements, and does not replace, the deterministic `check-frames.sh` comparisons. Builds and shared fleet tooling are owned by `old-mac-build-host`.
Sections: Frame check, Relation to check-frames, Validation.

## Frame check

```sh
scripts/vm-frame-check.sh /tmp/quake2-gameplay.png
```

This host framebuffer smoke check claims `qemu-tiger3d`, refuses an overlapping game, plays `demo1.dm2` at 1024x768, captures through QEMU's monitor, and asks the engine to quit normally. The SSH session remains connected while the Tiger GUI process runs. Inspect the resulting image for rendering faults. VM lifecycle: `scripts/shared.sh qemu-vm.sh {up|down|status|doctor}`.

## Relation to check-frames

A wall-clock host capture is not a replacement for `check-frames.sh`'s deterministic guest-frame comparisons. Guest screenshot readback was broken on this target (matthewdeaves/qemu#7, this repo's #97) but is fixed upstream as of qemu#7 (b60a6d9936+, QemuMac#20 step 4): `screenshot.sh`/`check-frames.sh` now use the same frame-exact in-engine `screenshot` path here as every other machine (#105). Do not replace the reference image set with black guest screenshots or claim that an FPS pass proves visual correctness.

## Validation

2026-09-27: the helper captured visible `demo1.dm2` gameplay at 1024x768, including world textures, viewmodel and HUD, then logged a normal engine and SDL audio shutdown. The captured frame was visually inspected.
