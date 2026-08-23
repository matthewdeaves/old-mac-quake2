# 9. A smoke test is a demo run that auto-exits, and a benchmark states its conditions

Date: 2026-08-20 (records decisions taken 2026-05-31 and 2026-07-25)
Status: accepted

## Decision

**A smoke test is an actual demo run that auto-exits.** Proof of success is a
printed fps line, which means the world rendered through
`R_RenderView` / `R_MarkLeaves` to completion. Use
`scripts/bench.sh <machine> demo1 <WxH> 1`, or `scripts/smoke-dmg.sh` for the
production-config artifact test.

### Two methods are banned; both caused real damage on 2026-05-31

- **`+map <map>`** loads a map and sits there **fullscreen forever**. The
  process never exits, so it grabs the display. A failed kill left two G4s
  stranded on black screens, looking exactly like a crash.
- **Engine-load-only / "did it start" checks** do not exercise world rendering,
  which is where the real crashes live.

### A clean demo does not clear a gameplay crash

"Start a new game" spawns a live server and entities, a different path from demo
playback. For an in-game regression, test a real new game as well.

**`+map base2` is not "new game".** The proper first level is **base1**, and its
content is what triggers bugs: base1's non-warp glass windows exposed the
`gl_trans_lighting` `ERR_DROP` (ADR 0010), while base2's translucent surfaces
are mostly `SURF_DRAWTURB` water, which the lightmap path early-returns on. A
direct `+map base2` looked like it loaded fine.

### An `ERR_DROP` presents as a freeze, not a crash

`ERR_DROP` longjmps back and drops to a full console, which the engine then
redraws forever (`SCR_UpdateScreen → Con_DrawConsole → CGLFlushDrawable`). The
process stays alive with pegged CPU and ignores SIGTERM, and there is no crash
log. **Read the flushed log first.** The production launch uses `logfile 1`
(buffered), so the error never reaches disk; reproduce with `+set logfile 2`
and, on hazardous machines, `+set vid_fullscreen 0`.

### Killing a run: TERM: sleep, then KILL

Always. SIGTERM lets SDL restore the captured display; a hard SIGKILL
black-screens the R300/Leopard iMac G5 (ADR 0008). `bench.sh` does this already.

## Two launch modes, and which one to use

- **`bench.sh` / `screenshot.sh`, deterministic measurement.** Pass
  `-noarchautoexec` to suppress the bundle hook and drive video, resolution and
  sound via command-line `+set`. Use whenever a measurement must not be coloured
  by the per-machine production defaults.
- **`smoke-dmg.sh`, as a human launches it.** Does **not** pass
  `-noarchautoexec` and does not override video or resolution; the production
  bundle config drives the renderer and only a timedemo is added so it exits.
  This is the gate that caught the corrupt-DMG crash, and it confirms both world
  render and production resolution.

To A/B one cvar against the production config with no rebuild, use
`+cmd "set X Y"`. That is a **late** command, so it runs after the bundle exec
and overrides cleanly. If it wins, fold it into the machine's autoexec,
redeploy, re-bench.

## Q2 timedemo specifics

- `+timedemo demo1.dm2`, not `demo1`, the `.dm2` is required.
- Playback is initiated with `demomap demo1.dm2`, not `playdemo demo1`.
- The fps line is `N frames, X.X seconds: Y.Y fps`.
- Retail paks ship **two** playable demos, `demo1.dm2` (intro) and `demo2.dm2`
  (gameplay). **`demo3.dm2` is not in any retail pak** despite Q1's three-demo
  heritage; it fails with "Couldn't open demos/demo3.dm2". Bench scripts default
  to demo1 + demo2.
- `qconsole.log` is written to the writable gamedir, **`~/.yq2/baseq2/`**, not
  next to the binary. Bench scripts `+set logfile 2` to flush after every print.
- 5.11 selects a fixed mode table via `gl_mode` (0..N); for an arbitrary
  resolution use `gl_mode -1` + `gl_customwidth` + `gl_customheight`. There is
  no `r_mode` cvar.
- **A timedemo measures the INITIAL video mode.** Resolution and
  desktop-fullscreen cvars must be passed on the command line so they apply at
  init, before the first mode set. An autoexec `vid_restart` to change
  resolution lands too late for the measurement (and is unsafe on the G3 anyway,
  see `MISTAKES.md`).

## Cadence and record-keeping

Three runs, median of runs 2 and 3. Smoke bench on the dirty tree, commit the
code change, then `scripts/bench-and-commit.sh "<label>" --quick` on a clean
tree to land the official rows. Full grid only at end of round. **Never wipe
`benchmarks/results.csv` mid-round**, it is the canonical numeric record, one
row per (commit, machine, demo, resolution). Regressions worse than 5% on any
machine block the commit.

## Playability floors

- **G3 ≥ 20 fps.**
- **G4 ≥ ~40 fps** for feature work. It was 60 until 2026-05-29; the user
  preference is visuals over framerate, and the older floor is why several
  decisions in `MISTAKES.md` read as more conservative than they would be today.
- G5 and modern are uncapped; the G5 deliberately spends framerate on native
  resolution and MSAA (ADR 0008).

## The bench-integrity failure that made this ADR necessary

Nine rows recorded on **2026-06-06** carried `res=1`, a run count that landed in
the resolution argument. They therefore rendered **1x1 pixels** and reported
108–128 fps. Those rows are the evidence behind the v2.5.0 / v2.5.1 "stencil
shadows cost ~15% and clear the floor" decisions on all three G4s. The real
mini-g4 figure at 1024x768 is **38.8 fps**.

`bench.sh` now rejects a malformed resolution instead of quietly benching
nonsense. **Re-taking those stencil decisions was issue #7, closed 2026-08-23**:
mini-g4's real-resolution figure is 41.1 fps, above the floor, kept ON. Treat
any 2026-06-06 G4 stencil figure as unverified regardless (ADR 0010);
sawtooth and quicksilver still owe the same re-take.

## Machine state can move between runs, and it is not always the code

mini-g4 produced **97.50 fps** demo1 1024x768 early in a session and **56.8 fps**
later the same session, same binary, same config, and a clean reboot did not
restore it. Checks: 0% idle CPU, display still 1024x768 @ 60 Hz, `GL_RENDERER`
normal, demo1 ran 689 frames in 12.1 s (was 7.1 s). 56.8 is suspiciously close
to `60 x 16/17 = 56.5`, suggesting Quartz vsync, but an explicit
`SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, 0)` did not recover it and windowed
was slower still (44 fps).

Most likely thermal throttling: Tiger does not manage CPU temperature actively,
and the 1.25 GHz 7447A clock-throttles to roughly 800 MHz when hot, which
matches the fall. **Do not bench-validate a code change against numbers from a
hot machine**; wait for a cool-down, leave a gap between overnight batches, and
re-validate after a cold boot rather than chasing it in code. A defensive change
was kept: `SDL_GL_SWAP_CONTROL` is now set to 0 explicitly when
`gl_swapinterval` is 0 (previously only set when 1), so the OS default cannot
kick in unpredictably across reboots.

## Consequences

- Every benchmark row needs its conditions attached; a bare fps number is not a
  finding.
- A benchmark that looks impossible for the hardware is more likely a harness
  bug than a win.
