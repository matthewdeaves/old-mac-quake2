# Benchmarking & smoke testing — yquake2 PPC port

How to measure fps and how to prove a build works. Read this before running
`scripts/bench.sh`, `smoke-dmg.sh`, or `parallel-bench.sh`.

## What a smoke test MUST be (a demo run that auto-exits)

A smoke test is an **actual demo run that auto-exits** — use
`scripts/bench.sh <machine> demo1 <WxH> 1` (it runs `+set timedemo 1
+demomap demo1.dm2`, polls `qconsole.log` for the `frames…seconds…fps`
line, then `killall`s), or `scripts/smoke-dmg.sh` for the production-config
artifact test (below). Proof of success = an fps line printed (the world
rendered through `R_RenderView`/`R_MarkLeaves` to completion).

Two methods are BANNED — both caused real damage on 2026-05-31:
- **`+map <map>`** loads a map and sits there **fullscreen forever**; the
  process never exits, so it grabs the display. A failed kill left two G4s
  stranded on black screens, looking like a crash. A demo auto-exits.
- **Engine-load-only / "did it start" checks** don't exercise world
  rendering, where the real crashes live. The user explicitly rejected
  these. Always do a real demo run.

NB: a clean demo run does NOT clear a *gameplay* crash — `start a new game`
spawns a live server + entities, a different path from demo playback (e.g.
the 2026-05-31 G3 `R_MarkLeaves` in-game fault that the demo did not hit).
For an in-game regression, also test an actual new game, not just a demo.

**Killing a fullscreen run: ALWAYS `killall -TERM` first, then `-KILL` as a
backstop.** SIGTERM lets SDL restore the captured display; a hard SIGKILL
black-screens the R300/Leopard iMac G5. `bench.sh` already does
TERM→sleep→KILL.

## Two ways to launch — pick the right one

- **`bench.sh` / `screenshot.sh` (deterministic measurement)** pass
  `-noarchautoexec` to suppress the bundle hook, and drive vid/res/sound via
  cmdline `+set`. Use this whenever a measurement shouldn't be coloured by the
  per-machine production defaults (resolution sweeps, A/B cvar runs).
- **`smoke-dmg.sh` (as-a-human-launches)** does NOT pass `-noarchautoexec` and
  does NOT override vid/res — the production bundle config (per-arch baseline +
  per-machine overlay) drives the renderer; only a timedemo is added so it
  auto-exits. This is the gate that catches bugs the deploy+bench path misses
  (e.g. the corrupt-DMG crash). Confirms world render AND production resolution.

To A/B a single cvar against the production cfg, use `+cmd "set X Y"` (a LATE
command, runs after the bundle exec, overrides cleanly). If it wins, fold it
into `scripts/bundle/autoexec-<machine>.cfg`, redeploy, re-bench.

## Bench-and-commit cadence (carry over from QuakeSpasm)

Same discipline: smoke bench on dirty tree, commit code change, then
`scripts/bench-and-commit.sh "Phase X" --quick` on clean tree to land
the official benchmark rows. Full grid only at end-of-round. Never
wipe `benchmarks/results.csv` mid-round.

## Q2 timedemo specifics (differ from Q1)

- Q1: `+timedemo demo1` — Q2: `+timedemo demo1.dm2` (the `.dm2` is required;
  they're separate files in `baseq2/demos/`).
- Playback is initiated via `demomap demo1.dm2`, not `playdemo demo1`.
- The fps line is `N frames, X.X seconds: Y.Y fps`.
- Q2 retail paks (pak0/pak1/pak2) ship TWO playable demos: `demo1.dm2`
  (intro flythrough) and `demo2.dm2` (gameplay). Despite Q1's three-demo
  heritage, Q2's `demo3.dm2` is NOT in any retail pak — it fails with
  "Couldn't open demos/demo3.dm2". Bench scripts default to demo1+demo2 only.
- `qconsole.log` is written by default (logfile cvar default 1) to the
  writable gamedir: `~/.yq2/baseq2/qconsole.log` (NOT `baseq2/` next to the
  binary). Bench scripts `+set logfile 2` to flush after every print.
- Resolution: 5.11 selects a fixed mode table via `gl_mode` (0..N); for
  arbitrary res use `gl_mode -1` + `gl_customwidth` + `gl_customheight`.

## Playability floors

- G3 ≥ 20 fps; G4 onward historically ≥ 60, but the **G4 feature-work floor is
  now ~40 fps** (user pref: visuals over framerate). The iMac G5 trades fps for
  native res + MSAA (~50 fps benched / ~30 fps as-played at 1440×900 + 2× MSAA).
- See `docs/imac-g5-leopard-port-notes.md` for the R300 fullscreen safety rail
  the bench scripts enforce on the G5.
