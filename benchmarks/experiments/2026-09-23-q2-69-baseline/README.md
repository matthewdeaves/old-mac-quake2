# #69 per-class baseline and #86 G5 tower A/B, 2026-09-23

Installed build: v2.14.0 on every host (engine md5 `586c7597…`). `bench.sh`,
demo1, each Mac's shipped profile, vsync off, 3 runs with the cold run dropped.
Cells were A (shipped), then viewsize 40 (a smaller 3D view: if fps jumps, the
Mac is fill-bound), then A again. Rows and raw logs are in this directory.

| Class | Drawable | Shipped A1 / A2 | viewsize 40 | Floor | Verdict |
|---|---|---:|---:|---:|---|
| G3 Rage 128, Panther (yosemite) | 1024x768, mode switch | 25.7 | lost claim | 20 | above floor |
| G4 Radeon 9200 (mini-g4) | 1024x768 | 54.6 / 53.7 | 100.6 | ~40 | fill-bound |
| G5 dual 2.7 Radeon 9600, Tiger (g5-tiger) | 1680x1050 | 50.7 / 50.8 | 72.0 | ~40 | fill-bound |
| Core 2 Duo GeForce 9400M (mini-sl) | 1920x1080 | 47.2 / 46.0 | 68.3 | — | fill-bound |
| Core 2 Duo GMA 950 (mini-intel2) | 1024x768 | 58.7 / 58.8 | 127.7 | — | fill-bound |
| i5 Radeon Pro 580X, 8x + resolve (imac-2019) | 2560x1440 | 175.1 / 175.8 | 181.3 | — | fixed full-screen passes dominate; players see the ~119 vsync cap |
| Apple M5 (workstation) | 1920x1080 | not a class number | | — | load average 17 from agent sessions; runs spread 104-146 |

No class is under its floor. yosemite's first cell (13.05) was the first run
after a fresh deploy and smoke and is not used.

## #86: G5 tower effects (g5-tiger, 1680x1050, interleaved)

| Cell | fps |
|---|---:|
| shipped (A1-A4) | 50.65, 50.80, 50.60, 50.60 |
| + retexturing, aniso 16, glows, trans_lighting, caustics, stencil | 45.10, 45.20 |
| the same with aniso 2 | 45.75 |
| the same with stencil off, aniso 16 (shipped in rc1) | 50.15 |

The candidate cvars were passed as `+exec q2cand.cfg`, with the read-back
confirming each value. Invalid rows are kept in the CSV. Ignore:
- `q2-86 candidate B1`/`B2`/`B3` with a `+set` EXTRA (NA): bench.sh's own
  arguments plus six `+set`s exceed the engine's 50-argument limit ("argc >
  MAX_NUM_ARGVS"), so the engine exits at start.
- `q2-86 candidate … (exec cfg)` at 50.6: the file was named
  `q2-86-cand.cfg`, the engine exec'd `q2` ("couldn't exec q2"), and the
  read-back shows shipped values.
