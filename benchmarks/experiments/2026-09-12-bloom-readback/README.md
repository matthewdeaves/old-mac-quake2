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

The source stamp includes the pre-existing, user-owned working-tree SDL
framework binary (`MacOSX/SDL.framework/Versions/A/SDL`, SHA-256
`5db4a0fd33a01f035745eb983f32f78536cd127f390364d41e0349d8d9678588`).
This investigation neither altered nor stages that file. Consequently this is
an unpublished test candidate, not an artifact reproducible solely from the
bloom commit until that separate work-in-progress file is resolved by its
owner.

## Visual results

| Class | Result | Evidence |
| --- | --- | --- |
| Apple Silicon, Apple M5, macOS 26.6.2 | Manual pass on the earlier candidate. The user played and reported that it looked really nice. The log reported zero GL errors for capture, downsample, darken, both blur passes and composite. The final rebuilt candidate still needs the user's manual pass. | `frames/apple-silicon-user-pass.png` |
| G5, Radeon 9600, Panther 10.3.9 | Manual pass at native 1680x1050 on the earlier candidate. The user reported that it looked great and smooth. The final candidate's automated bloom-on frame is visible and textured, and its log reports GL error 0 for every bloom stage. | `frames/g5-user-pass.png`, `frames/g5-final-bloom-on.png` |
| G4, Radeon 9000, Tiger 10.4.11 | The final candidate's automated bloom-on frame is visible and textured. No user gameplay pass on the final candidate yet. | `frames/g4-final-bloom-on.png` |
| G3, Rage 128, Tiger 10.4.11 | The earlier automated frame is visible and textured with bloom. The user said it looked lovely but was incredibly slow and directed that bloom not be enabled by default. A ten-frame final-candidate bloom capture was stopped because it was too slow to add useful evidence; the final shipped-profile benchmark below confirms bloom remains off. | `frames/g3-bloom-on.png` |
| Intel, GMA 950, Lion 10.7.5 | Untested. The current mini has no display listed by `system_profiler`. Candidate bloom-on, candidate bloom-off and a prior-build bloom-on control all produced byte-identical corrupted engine screenshots in its 800x600 Quartz session. Their FPS values are invalid. | `frames/intel-headless-invalid.png` |
| Intel, Radeon Pro 580X, macOS 15.7.9 | Final six-slice candidate installed and x86_64 host/slice verified. The built-in 5K LCD was online and main, but `system_profiler` reported `Display Asleep: Yes`; no capture was accepted as displayed-frame evidence. | Visual test pending an awake display. |

The Apple Silicon and G5 screenshots accompany real user observations. The G3
and G4 files are engine screenshots. The GMA 950 file documents an invalid
headless capture and is not evidence of the displayed frame. The Radeon Pro
580X preflight verified console user `mini`, a running WindowServer, readable
retail paks, a writable user game directory, the six-slice app and the exact
fat binary hashes above before rejecting the asleep display as a visual-test
precondition.

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
| Apple Silicon | Not measured | Not measured | Do not change the default from visual evidence alone. |

No release or publication is authorized. The final candidate still needs an
awake display-backed Intel test and the user's release-gate gameplay passes on
the final artifact. The GMA 950 visual cell remains explicitly untested.
