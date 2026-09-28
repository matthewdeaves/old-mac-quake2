# Quake II fleet operations as job definitions

Every operation in this repo that touches a machine: script, inputs, outputs, and whether it needs the machine to itself. Written as input to `old-mac-build-host#15` (Jenkins on u25), read from the scripts on 2026-08-23 at `45ca55f0`.
The key rule: concurrency is keyed on the physical machine, not the alias; engine jobs are mutually exclusive per machine because they `killall` each other; never substitute hardware when a target is busy.
Sections: Concurrency key, Why engine jobs exclude each other, Exclusive jobs, Non-exclusive jobs, Queue rule. Bench-row schema gaps moved to `docs/BENCH-PROVENANCE.md`.

## Concurrency key

Fourteen bench aliases resolve to ten machines. From the workstation's `~/.ssh/config`:

    yosemite, yosemite-tiger              10.188.1.128
    g5-panther, g5-tiger, g5-desktop      10.188.1.188
    quad-tiger, quad-leopard              10.188.1.120
    sawtooth 10.188.1.24   quicksilver 10.188.1.85   mini-g4 10.188.1.62
    imac-g5  10.188.1.168  mini-sl     10.188.1.201
    mini-intel 10.188.1.245  mini-intel2 10.188.1.164

The multi-alias entries are one Mac with several OS partitions, one booted at a time (`pick-bench-host.sh:66-67`). A queue keyed on alias will run `yosemite` and `yosemite-tiger` at once; they are the same 449 MHz G3.

Worse than sharing: booting one partition destroys whatever is running on its sibling, and the victim reads as an unreachable machine rather than an error. A partition switch is an exclusive claim on the whole Mac.

`imac-g5` (10.188.1.168) is a different machine from the `g5-*` aliases (10.188.1.188), despite the names.

## Why engine jobs exclude each other

Process kills, not measurement noise. `bench.sh:310`, `smoke-dmg.sh` and `screenshot.sh` all end in `killall -TERM quake2`. Any two on one Mac terminate each other's engine mid-run, and the victim reports a timeout, which looks like a slow machine rather than a collision.

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

## Non-exclusive jobs

    build-arm64        scripts/build-arm64.sh
    build-server-linux scripts/build-server-linux.sh
      concurrency   NONE. Touch no fleet machine: workstation and a Debian
                    container. Never queue them behind hardware.

    analyze         scripts/analyze.sh [refresh]
      concurrency   NONE. Local static analysis.

    config read-back    DOES NOT EXIST YET
      proposed      ssh <machine>, cat the shipped overlay and
                    ~/.yq2/baseq2/config.cfg, emit cvar=value pairs
      concurrency   NONE. Read-only, safe alongside a bench.

Nothing reads the installed config back off a machine today; `bench.sh:147` and `deploy.sh:182` mention `config.cfg` in comments only. It is worth building: the engine writes archived cvars to `config.cfg` on every clean exit, so a value a bench pinned is still there afterwards. Anything the shipped config chain does not explicitly set persists, live, on a machine that no longer represents the product, and poisons the next measurement. A read-back after every bench turns that from invisible into a diff.

## Queue rule

Never let a job pick a different machine because its target is busy. If the G4 is claimed, the G4 bench waits or fails. Substituting hardware produces a row correct in every field except the one that matters.
