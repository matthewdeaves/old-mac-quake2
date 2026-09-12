# Bloom framebuffer readback investigation

Issue #33, 2026-09-12. The user reported a black screen after enabling
`gl_bloom` on the current Apple Silicon Mac.

## Cause and candidate

Source inspection found that sdl12-compat can render SDL 1.2 fullscreen output
through its own multisample framebuffer. The engine loaded
`glCopyTexSubImage2D` and `glReadPixels` directly from OpenGL before SDL created
the context. That bypassed sdl12-compat's resolve-aware wrappers.

The candidate now checks for sdl12-compat after `R_SetMode` creates the context.
When present, it obtains both readback entry points through
`SDL_GL_GetProcAddress` and replaces the public QGL pointers and their logging
backing pointers. Genuine SDL 1.2 retains its original OpenGL bindings. Bloom
also prints the GL error from each stage once per context.

The initial performance build used source stamp `f0ed943c21f6`. It was based
on commit `d0313e1a` plus uncommitted renderer changes. The CSV's `commit`
field names that base commit, not the dirty candidate; the source stamp is the
candidate identity.

The final candidate was rebuilt from source stamp
`71dc862afcbd7bc6121d629442e5f517a2a8b1edd6d88a9ef500ca2d7802795d`.
`scripts/build-fat.sh` passed and verified that all four products contain all
six declared slices (`ppc750`, `ppc7400`, `ppc970`, `i386`, `x86_64`, and
`arm64`). Its fat artifacts are:

- `quake2`: `285283d66487e7334314e37c8884a70e337d0e1ccdbf2044d23b3769b4327a3d`
- `ref_gl.so`: `24aa39d7bb12ff638d70cfa4f54d3c8b5d7a859c9f9f0ddc7a89c76f677a805f`
- `baseq2/game.so`: `4489ef0afdd66dc831d4114ba8fdbc68ec6395a35b9b7c99de3a5366bd2c6598`
- `q2ded`: `f64f9e9692ba896d78b3db824a78b9bb052c93522ed047b6a49466cc8ed26779`

The app is installed as `bloom-fix-71dc862afcbd` on `yosemite-tiger`,
`quicksilver`, `g5-panther`, and `imac-2019`. The Intel install matches the
SHA-256 values above. The three legacy installs match the build by BSD MD5
(`shasum` is not present on Panther/Tiger): `2ed97fc58b43bca55ba6124f98ad440e`,
`957beed3572e3db6ce34f5099c16169a`,
`11413655de8d1c14a3b7bbc9ca000d05`, and
`a912294eb83833b7add31e4f6540e64f`, in the same product order.

The same exact DMG is also installed at `/Applications/Quake2` on `mini-g4`,
`mini-intel2` and the Apple Silicon workstation. The workstation's installed
engine, renderer and game library match the mounted DMG by MD5. The `mini-g4`
install copied its legacy `baseq2` without modifying the rollback tree, removed
the stale loose autoexec, byte-verified the staged runtime and passed the
Finder-equivalent smoke on the Radeon 9200.

The source stamp includes the pre-existing, user-owned working-tree SDL
framework binary (`MacOSX/SDL.framework/Versions/A/SDL`, SHA-256
`5db4a0fd33a01f035745eb983f32f78536cd127f390364d41e0349d8d9678588`).
This investigation neither altered nor staged that file. The clean-worktree
control below establishes that the canonical build recipe regenerates those
exact SDL input bytes from tracked sources; the input does not depend on an
unknown or unrecoverable private file. The already-tested candidate remains
the unpublished candidate. Exact byte-for-byte reproduction of its signed
final artifacts is a separate claim and is not established by that control.

### SDL input provenance and tracked-file control

A clean detached worktree at `d6c4545` began with the tracked framework binary
at SHA-256 `6dd17a4569163659d40a4e26bc8b281797f748c7c97fdaf98efbab7c2b890376`.
Running the canonical `scripts/build-arm64.sh` there reproduced the main
working-tree modification exactly: its documented framework-staging step
re-fused a freshly signed sdl12-compat arm64 member into the tracked fat
framework, changing the file to the same `5db4a0fd...` hash before computing
the arm64 source stamp. The subsequent fat build passed with all six slices at
stamp `4a74d93842df86c28be005d251a18fa211243370373da2c9981dbe62cf44be1c`.

The control's final artifacts did not match the tested candidate's hashes:

- `quake2`: `5079179ff3c0f81057e6356e88a9521997684d09fd1437df56d34d2f14afbe67`
- `ref_gl.so`: `8cdb61f23c17491a40fe6e0eb9c71e3fe0fde4a74b84a0519d6b5357726a4cbd`
- `baseq2/game.so`: `d99b28ab7b7d5a4dd1cf72fb9674a7bf94d620049ed03a8d37fba412c57148d7`
- `q2ded`: `783dbbe61c8c11fdf2d26ba7d1237af79bd7e4b301b28d1ba08dd2094c5e2e77`

Because the control used a different source stamp, this comparison does not
isolate signing or build determinism. It proves the SDL input recipe and slice
coverage, not exact final-artifact reproducibility, and does not replace the
tested `71dc862a...` candidate.

This establishes how the modified bytes were produced, but does not change
their ownership or authorize committing them. It also means a canonical build
that leaves the tracked framework byte-identical is not a viable independent
control: the current arm64 driver intentionally refreshes that member. The
original main-tree file remains untouched and unstaged, with an exact private
backup retained under the fleet scratch area.

## Visual results

| Class | Result | Evidence |
| --- | --- | --- |
| Apple Silicon, Apple M5, macOS 26.6.2 | Manual pass on the earlier candidate. The user played and reported that it looked really nice. The log reported zero GL errors for capture, downsample, darken, both blur passes and composite. The final rebuilt candidate still needs the user's manual pass. | `frames/apple-silicon-user-pass.png` |
| G5, Radeon 9600, Panther 10.3.9 | Manual pass at native 1680x1050 on the earlier candidate. The user reported that it looked great and smooth. The final candidate's automated bloom-on frame is visible and textured, and its log reports GL error 0 for every bloom stage. | `frames/g5-user-pass.png`, `frames/g5-final-bloom-on.png` |
| G4, Radeon 9000, Tiger 10.4.11 | The final candidate's automated bloom-on frame is visible and textured. No user gameplay pass on the final candidate yet. | `frames/g4-final-bloom-on.png` |
| G3, Rage 128, Tiger 10.4.11 | The earlier automated frame is visible and textured with bloom. The user said it looked lovely but was incredibly slow and directed that bloom not be enabled by default. A ten-frame final-candidate bloom capture was stopped because it was too slow to add useful evidence; the final shipped-profile benchmark below confirms bloom remains off. | `frames/g3-bloom-on.png` |
| Intel, GMA 950, Lion 10.7.5 | Untested. The current mini has no display listed by `system_profiler`. Candidate bloom-on, candidate bloom-off and a prior-build bloom-on control all produced byte-identical corrupted engine screenshots in its 800x600 Quartz session. Their FPS values are invalid. | `frames/intel-headless-invalid.png` |
| Intel, Radeon Pro 580X, macOS 15.7.9 | Automated pass on the final artifact. A bounded `caffeinate` assertion woke the online built-in panel; matching bloom-off/on LaunchServices processes reported the effective settings below. Both ten-frame sets show a textured world/HUD, bloom changes the pixels, and all bloom stages report GL error 0. | `frames/intel-radeon-off-control.png`, `frames/intel-radeon-bloom-on.png`, `intel-radeon-validated.txt` |

The Apple Silicon and G5 screenshots accompany real user observations. The G3
and G4 files are engine screenshots. The GMA 950 file documents an invalid
headless capture and is not evidence of the displayed frame. The Radeon Pro
580X preflight verified an active Aqua session, a running WindowServer,
readable retail paks, a writable user game directory, the six-slice app and
the exact fat binary hashes above. Its first capture was rejected because the
panel was asleep. The corrected run used the target's documented temporary
display-wake primitive inside the normal claim, verified the panel awake and
the assertions active, then restored the original config byte-for-byte and
removed the assertions.

## Final candidate shipped-profile checks

These are candidate-only runs of source stamp `71dc862afcbd`; they are not an
A/B performance comparison. `scripts/bench.sh` forced fullscreen, vsync off,
the stated resolution and the normal per-machine profile. Complete logs name
the actual GL renderer. Bloom's one-shot diagnostic appeared on the G5 and
reported GL error 0 for capture, downsample, darken, both blur passes and
composite. It did not run on the G3 or G4, consistent with their bloom-off
profiles.

| Class | Effective feature profile | Runs | Warm median |
| --- | --- | --- | ---: |
| G3 Rage 128, Tiger 10.4.11 | bloom off, 1024x768 fullscreen, vsync off | 25.8 / 25.8 / 25.9 | 25.85 fps |
| G4 Radeon 9000, Tiger 10.4.11 | bloom off, 1024x768 fullscreen, vsync off | 61.6 / 61.9 / 61.8 | 61.85 fps |
| G5 Radeon 9600, Panther 10.3.9 | bloom on, 1680x1050 fullscreen, vsync off | 50.2 / 50.3 / 50.3 | 50.30 fps |
| G4 Radeon 9200, Tiger 10.4.11 | bloom off, 2x MSAA, 1024x768 desktop-fullscreen, vsync on | 29.8 / 29.8 / 29.8 | 29.80 fps |
| G4 Radeon 9200, Tiger 10.4.11 | bloom off, 2x MSAA, 1024x768 desktop-fullscreen, vsync off | 40.5 / 40.6 / 40.6 | 40.60 fps |
| Apple M5, macOS 26.6.2 | bloom on, darken 1, 4x MSAA, 1920x1080 desktop-fullscreen, vsync off | 265.2 / 263.6 / 265.5 | 264.55 fps |

## Exploratory performance

`results.csv` preserves the raw figures and labels invalid rows. These runs were
not interleaved, so they are directional evidence rather than the final release
comparison.

| Class | Bloom off | Bloom on | Decision |
| --- | ---: | ---: | --- |
| G3 Rage 128 | 25.85 fps warm median | 2.2 fps, one run only | Keep off. The user made the default decision after seeing it. |
| G4 Radeon 9000 | 61.80 fps warm median | 21.50 fps warm median | Keep off. Bloom falls below the 40 fps G4 floor. |
| G5 Radeon 9600 | 153.20 fps warm median | 50.30 fps warm median | Bloom stays available and the existing G5 profile can keep it on. It remains above the 40 fps legacy floor. |
| Intel GMA 950 | Invalid | Invalid | No decision from this environment. Keep existing conservative default pending a display-backed test. |
| Apple Silicon | Not remeasured in this candidate-only pass | 264.55 fps warm median | Enable bloom with darken 1. The exact installed artifact completed all runs with live readback confirming the effect and production fullscreen path; the user's earlier visual pass supports the decision but does not replace final successor acceptance. |

## Config-only arm64-default successor

Commit `943c256a` changes only the arm64 bundle profile to `gl_bloom 1` and
`gl_bloom_darken 1`. The unpublished Panther-compatible DMG is
`dist/Quake2-OldMac-bloom-fix-arm64-on-943c256a.dmg`, SHA-256
`8c507473a14ce4dd2b9d6b4078001e9ee7c7209bed3722e36565c465f41d2247`.
It repackages the exact signed runtime extracted from the preserved
`f7921e27...` DMG, plus the matching SDL framework and SDL2 companion; it is a
documented config-only successor, not a new code build. Artifact audit found
all six slices, a valid deep code signature, the arm64 SDL2 companion, and the
expected effective bundle values: bloom 1, darken 1, 4x MSAA, fullscreen
desktop capture and vsync 1. It is not yet installed over the workstation's
tested candidate because the canonical fresh installer correctly refuses an
occupied destination and an update must retain that install as a named
rollback.

No release or publication is authorized. The final candidate still needs the
user's release-gate gameplay passes on G3, G4, G5, Intel and Apple Silicon.
The automated Intel Radeon test used matched 1024x768 settings; the user's
test must exercise the shipped desktop-fullscreen profile. The GMA 950 visual
cell remains explicitly untested.
