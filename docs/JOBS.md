# Quake II fleet operations as job definitions

Input to `old-mac-build-host#15` (Jenkins on u25). Every operation in this repo
that touches a machine: script, inputs, outputs, and whether it needs the
machine to itself. Read from the scripts on 2026-08-23 at `45ca55f0`.

## The concurrency key is the machine, not the alias

Fourteen bench aliases resolve to ten machines. From the workstation's
`~/.ssh/config`:

    yosemite, yosemite-tiger              10.188.1.128
    g5-panther, g5-tiger, g5-desktop      10.188.1.188
    quad-tiger, quad-leopard              10.188.1.120
    sawtooth 10.188.1.24   quicksilver 10.188.1.85   mini-g4 10.188.1.62
    imac-g5  10.188.1.168  mini-sl     10.188.1.201
    mini-intel 10.188.1.245  mini-intel2 10.188.1.164

The multi-alias entries are one Mac with several OS partitions, one booted at a
time (`pick-bench-host.sh:66-67`). A queue keyed on alias will run `yosemite`
and `yosemite-tiger` at once. They are the same 449 MHz G3.

Worse than sharing: booting one partition destroys whatever is running on its
sibling, and the victim reads as an unreachable machine rather than an error.
A partition switch is an exclusive claim on the whole Mac.

`imac-g5` (10.188.1.168) is a different machine from the `g5-*` aliases
(10.188.1.188), despite the names.

## Why the engine jobs are mutually exclusive

Process kills, not measurement noise. `bench.sh:310`, `smoke-dmg.sh` and
`screenshot.sh` all end in `killall -TERM quake2`. Any two on one Mac terminate
each other's engine mid-run, and the victim reports a timeout — which looks
like a slow machine rather than a collision.

## Exclusive jobs

    bench           scripts/bench.sh <machine> <demo> <WxH> [runs]
      inputs        machine, demo, res, runs (3), EXTRA (+set tokens), NOTES,
                    per-machine TIMEOUT/COOLDOWN (bench.sh:177-187)
      outputs       row in benchmarks/results.csv, raw logs in benchmarks/raw/
      exclusive     it is the measurement

    smoke-dmg       scripts/smoke-dmg.sh <machine>
      inputs        machine, TIMEOUT/COOLDOWN (smoke-dmg.sh:51-66)
      outputs       pass/fail on an fps line
      exclusive     launches the engine fullscreen and killalls it
      note          production path: no -noarchautoexec, no vid/res override
                    (:5, :89). Its number is the vsynced one; bench's is not.

    deploy          scripts/deploy.sh <machine>          developer, rsync
    deploy-dmg      scripts/deploy-dmg.sh <machine> [version]   release
      outputs       installed tree, md5-verified against the image
      exclusive     rewrites the binary a bench would be reading

    screenshot      scripts/screenshot.sh <machine>
      inputs        machine, DEMO, SHOT_DIR (docs/screenshots/)
      exclusive     stages a cfg into baseq2/, launches, killalls

    check-frames    scripts/check-frames.sh <machine> [--update]
      inputs        machine, DEMO, THRESHOLD (0.04)
      outputs       per-frame RMSE vs tests/frames/
      exclusive     DURING CAPTURE ONLY. Takes no lock itself (:77) because it
                    delegates to screenshot.sh, which claims. Split it: a
                    capture stage that holds the machine, a compare stage that
                    does not.

    make-dmg        scripts/make-dmg.sh
      inputs        DMG_HOST (a Tiger G4), build/q2-fat/
      outputs       dist/Quake2-OldMac-<version>.dmg
      exclusive     on the packaging Mac. Must be a Tiger G4: Lion's hdiutil
                    cannot write a Panther-mountable image and no flag fixes
                    it. Not a preference the job may override.

    build/build-fat scripts/build.sh <g3|g4|g5|lion> | scripts/build-fat.sh
      outputs       build/q2-fat/: quake2 q2ded ref_gl.so baseq2/game.so
      exclusive     PER MINI, and not about noise: two PPC builds on one mini
                    share a single -arch ppc object tree and race the .o files
                    into the wrong CPU-subtype stamp, producing a binary that
                    refuses to exec on a G3. Two minis exist so two builds can
                    run at once, on DIFFERENT minis. Model two resources, not
                    two slots on one host.

    tidy-quicksilver  scripts/tidy-quicksilver.sh (DRY_RUN=1 default)
      exclusive     it deletes files

## Non-exclusive

    build-arm64        scripts/build-arm64.sh
    build-server-linux scripts/build-server-linux.sh
      concurrency   NONE. Touch no fleet machine — workstation and a Debian
                    container. Never queue them behind hardware.

    analyze         scripts/analyze.sh [refresh]
      concurrency   NONE. Local static analysis.

    config read-back    DOES NOT EXIST YET
      proposed      ssh <machine>, cat the shipped overlay and
                    ~/.yq2/baseq2/config.cfg, emit cvar=value pairs
      concurrency   NONE. Read-only, safe alongside a bench.

Nothing reads the installed config back off a machine today; `bench.sh:147` and
`deploy.sh:182` mention `config.cfg` in comments only. It is worth building.
The engine writes archived cvars to `config.cfg` on every clean exit, so a
value a bench pinned is still there afterwards. Anything the shipped config
chain does not explicitly set persists, live, on a machine that no longer
represents the product, and poisons the next measurement. A read-back after
every bench turns that from invisible into a diff.

## Parameters are provenance: what a bench row cannot say

The header, `bench.sh:259`:

    timestamp,commit,build_type,machine,cpu,gpu,os,demo,res,
    run1_fps,run2_fps,run3_fps,median_fps,notes

1. **vsync is forced off and no column says so.** `bench.sh:301` hardcodes
   `+set gl_swapinterval 0`. The engine default is 1 and no bundle layer sets
   it for any PowerPC machine. Every PowerPC row here is a number no player has
   seen. Measured on mini-g4: 41.10 vsync off, 29.90 on. Both are "the mini-g4
   result" and the file cannot tell them apart.

2. **Overridden cvars land in prose.** `EXTRA` is appended to `notes` (:243,
   :252), commas rewritten to semicolons, truncated at 240 chars (:254).
   Captured, but not queryable and silently lossy.

3. **The baseline is not recorded.** `bench.sh` does not pass
   `-noarchautoexec`, so the shipped overlay and the machine's archived
   `config.cfg` are both live under the cmdline `+set`. `commit` makes the
   overlay derivable; the archived config is derivable from nothing.

Proposed row — as a job these are recorded automatically instead of by a human
remembering to set NOTES:

    timestamp, commit, build_type, machine, cpu, gpu, os, demo, res,
    vsync,            0 or 1, explicit, never inferred
    cvar_overrides,   structured k=v, not prose, not truncated
    config_sha,       sha of the machine's config.cfg at run time
    overlay,          which autoexec-<machine>.cfg was in effect
    timeout_s, runs,
    run1_fps..runN_fps, median_fps, spread_fps,
    outcome,          OK | TIMEOUT | FAILED, never blank
    notes

`spread_fps` matters as much as the median: a mean and a
median-of-runs-2-and-3 disagreed in sign on the same three-run data at a 3 fps
spread. `outcome` splits the three states the schema collapses into `NA` — the
run finished, ran out of time, or failed. Only the first is a measurement.

A timeout expiring says the run did not finish in the time allowed and nothing
else. Timeouts must be job parameters, not the constants at `bench.sh:177-187`.

`bench.sh` already defeats stale-log fabrication: it deletes
`~/.yq2/baseq2/qconsole.log` before each run (:292) and writes `NA` when no fps
line appears (:340). Keep both. A job reusing a fixed output path that carries
on after a failed fetch will parse the previous run's number and emit a
complete, plausible, fabricated row.

## One thing the queue must not do

Never let a job pick a different machine because its target is busy. If the G4
is claimed, the G4 bench waits or fails. Substituting hardware produces a row
correct in every field except the one that matters.
