# Mistakes: build, packaging and deploy

Settled negatives from building, packaging and deploying the fat app. Themes: a gate must be proved to pass good input as well as refuse bad; a verification tool returning nothing is not proof; verify at the last hop the user runs; do not blame flaky retro hardware before hashing in place. Mechanisms that became standing decisions live in `docs/adr/`; those entries are pointers. Newest first.

## 2026-08-28 create-dmg adoption rejected (#39)
Considered build-host's `create-dmg` drag-to-Applications layout (`lay-out-dmg.sh`); rejected without shipping. It needs Homebrew and a live Finder, so it must run on a modern host, but `make-dmg.sh` runs `hdiutil create` on a Tiger G4 (`quicksilver`/`mini-g4`) because Lion's `hdiutil` writes a UDIF container the Panther G3 cannot mount, and no flag fixes it (ADR 0005, measured).
A modern host (the workstation is macOS 26, 14 years newer than the proven-bad Lion case) reintroduces that break, worse: a newer container format never regains old-OS readability. Not live-retested on Panther (`yosemite` was mid-OS-switch); inferred from ADR 0005, and the direction only worsens with a newer host.
A second modern-only DMG just for the layout was rejected as unrequested complexity for one fat cross-arch release.

## 2026-08-22 A staleness gate caught its bug and refused every good build (#17)
`build-fat.sh` fused an arm64 slice built three hours before the source of the other five, printed "fusing SIX", exited 0. The content-hash gate added to stop that was tested only against a reproduction of the stale slice, passed, shipped, then refused a fully current build twice for two unrelated reasons: the staged arm64 dir never received its `SOURCE-STAMP`, and `build-arm64.sh` computed its stamp while its temporary Makefile edit was applied, recording a tree state the EXIT trap reverted moments later. Commits `ea922696`, `0b526e06`, `cabeae7e`.
Lesson: a check that REFUSES bad input must be proved to PASS good input; the passing direction is the one that gets skipped, and a gate that blocks legitimate work gets switched off. Corollaries: a driver that mutates the tree to build must compute its stamp BEFORE the mutation (checked against where the trap fires, not where the write sits); an output dir inside the source tree must be excluded from the hash.

## 2026-08-22 `strings` showed three of six slices with no architecture string
Verifying that each slice of the fused `baseq2/game.so` self-identifies, the PowerPC slices came back empty while `amd64`, `i386`, `arm64` read fine. `strings` defaults to a 4-character minimum and `ppc` is three: use `-n 3`.
*A verification tool returning nothing is not evidence the property is absent.* Dangerous because it is a false NEGATIVE in exactly the check `docs/adr/0006` exists to make people run, and plausible: the three PowerPC slices genuinely did report `unknown` before `0647fbcb`.

## 2026-07-25 `-faltivec` silently un-stamped the ppc7400 cpusubtype
Nearly shipped a fat no G3 could launch; caught before release. Root cause, blast radius and the assert-and-re-stamp fix: ADR 0001.
Lesson: a compiler flag added for one reason can quietly undo something unrelated three layers down; the only defence is asserting the property you care about on the artifact itself.

## 2026-05-31 Phantom "G3 corrupt renderer" was my own stale DMG mounts
Root cause and deploy-verify fix: ADR 0006. I assumed flaky retro hardware (old disk, non-ECC RAM); wrong: the G3 has a near-new SSD, hashed the file `060cc6dc…` three times deterministically in place, and a copy-to-disk hashed clean.
Do not reach for "flaky retro hardware" before hashing the file in place and copy-testing it. Verify at the LAST hop the user runs (the install directory); a failing deploy that prints a success-ish line is worse than one that errors.

## 2026-05-31 DMG packaging flipped ONE byte, illegal-instruction crash on every G4
Root cause, opcodes and three-part fix: ADR 0006. `hdiutil verify` is not a content check. Do not run build or packaging on the flakiest hardware in the fleet when a healthier machine does the same job.

## 2026-05-31 Config comments overflowed the command buffer and wedged the R300 on "new game" (v2.2.0)
Garbled config, R300 GPU wedged. Root cause and two-layer fix: ADR 0007.
Lessons: shipped config text has a hard size budget when the engine buffers it; a timedemo is not a substitute for actually starting a new game; when a change looks "harmless everywhere", check the machine with the least forgiving driver, which turns soft failures into hard ones.
