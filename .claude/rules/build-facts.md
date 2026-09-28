---
paths:
  - "scripts/build*.sh"
  - "scripts/make-dmg.sh"
  - "scripts/deploy*.sh"
  - "scripts/dmg-*"
  - "scripts/source-stamp*.sh"
  - "scripts/macho-archs.sh"
---

## Build facts

- **`-faltivec` silently defeats `-mcpu=7400` cpusubtype stamping**; a generic `ppc (ALL)` fat member makes the binary refuse to exec on a G3 under Tiger/Leopard while Panther accepts it. `build.sh` asserts and re-stamps all four artifacts after every PPC build. **Never remove that block.** `file` printing `ppc_650` for subtype 9 is a tool quirk; trust `lipo`. ADR 0001
- **Five slices cross-compile on an Intel Lion mini** (`mini-intel`/`mini-intel2`, interchangeable); `arm64` is built on the orchestration Mac by `build-arm64.sh`. Ask `scripts/shared.sh pick-build-host.sh`, never hardcode: the claim is a lock ON the host. ADR 0005
- **Never run two PPC builds on one mini**: they share one `-arch ppc` object tree and race `.o` files into the wrong subtype stamp. ADR 0005
- **Release DMG on a Tiger G4 only.** Lion's `hdiutil` writes an image Panther cannot mount; the 1999 G3 once flipped a byte and shipped a crash to every G4. ADR 0005
- **Never trust "done" or exit 0.** Verify the property on the artifact (`lipo -archs`, `otool -L`, `otool -h`) and md5 the bytes at the last hop the user runs. PPC builds are not byte-reproducible (~138 bytes); compare only artifacts from one run. ADR 0006
- **A smoke test is a demo run that auto-exits.** Never `+map` (grabs the display forever), never an engine-load-only check; a clean demo does not clear a gameplay crash, so also start a new game on base1. ADR 0009
- **`scripts/source-stamp.sh` is NOT ours to edit** (canonical in build-host, byte-identical across five repos, drift-checked). It takes the exclude list as an argument; ours is `source-stamp-excludes.sh`. Call sites: `build.sh:199`, `:257`, `build-fat.sh:140`, `build-arm64.sh:140`. Issue #20
