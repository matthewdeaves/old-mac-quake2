# imac-2019: MSAA, bloom and scene resolve, 2026-09-22

Trigger: the user reported that imac-2019 "could be smoother". The machine is
a Radeon Pro 580X on 15.7.9, running the installed v2.12.0 engine
(`2f7874dd…`) with its production profile. Every run is demo1 in desktop
fullscreen, where the scene renders at the desktop's 2560x1440, through
`bench.sh` with vsync off. Arms are interleaved, two runs each; the logs are
the `imac2019-ab*.log` files here and `benchmarks/raw/*imac-2019*`.

| arm | fps |
|---|---|
| shipped: bloom + 8x MSAA | 73.1-75.4 |
| 4x MSAA | 144.7-154.4 |
| 8x + `gl_bloom_fastrestore 1` | 63.5-67.7 |
| 4x + `gl_bloom_fastrestore 1` | 130.2-135.7 |
| 8x + `gl_scene_resolve 1` | 175.6-178.4 |
| 4x + `gl_scene_resolve 1` | 274.1-277.7 |
| bloom off | 429.3-430.1 |
| 8x, `gl_swapinterval 1` | 72.6-75.0 (vsync has no effect here) |

Shipped: 4x MSAA (40c43989).

Not shipped: 8x + scene resolve. The images show engine screenshots of both
8x variants at 2560x1440, which are visually equivalent. Scene resolve fails
closed when unsupported, and the game will not start, so a profile can't
enable it until it has a playable fallback. See #69.
