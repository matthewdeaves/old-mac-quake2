# Benchmarking and smoke testing

**Read ADR 0009 first.** It carries the rules: what a smoke test must be, the two
banned methods, the TERM-then-KILL requirement, the timedemo specifics, the
playability floors, and the `res=1` bench-integrity failure. This file is the
operational surface.

## Commands

```sh
scripts/bench.sh <machine> <demo> <WxH> [runs]   # deterministic measurement
scripts/smoke-dmg.sh <machine>                   # production-config artifact test
scripts/parallel-bench.sh [--quick]              # fleet grid
scripts/bench-and-commit.sh "<label>" --quick    # lands official rows on a clean tree
scripts/screenshot.sh <machine> …                # visual A/B
```

Machines: `yosemite`, `yosemite-tiger`, `sawtooth`, `quicksilver`, `mini-g4`,
`imac-g5`, `mini-intel`, `imac-2019`.

A smoke test is `scripts/bench.sh <machine> demo1 <WxH> 1`, or `smoke-dmg.sh`
for the shipped artifact. `bench.sh` runs `+set timedemo 1 +demomap demo1.dm2`,
polls `qconsole.log` for the `frames … seconds … fps` line, then kills.

## Safety rails the scripts enforce

- **`imac-g5`**: `bench.sh` refuses fullscreen at any non-native resolution
  (`exit 3`) and defaults to a native same-mode capture. `G5_WINDOWED=1` gives
  safe windowed iteration. `parallel-bench.sh` benches the G5 leg at native
  1440x900. **ADR 0008 — never bypass this.**
- **`yosemite` / `yosemite-tiger`** are one machine on one IP with two OS
  partitions, only one booted at a time. `parallel-bench.sh` refuses to run both
  legs. Switch with
  `ssh yosemite 'sudo bless --mount "/Volumes/<vol>" --setBoot'` then reboot with
  plain `sudo /sbin/reboot </dev/null` — **not** `sudo -n`, which Tiger's and
  Panther's sudo 1.6.x reject outright.
- Every run is TERM, sleep, KILL. Never a bare KILL.
- A malformed resolution is rejected rather than benched.

## Results

`benchmarks/results.csv` is the canonical numeric record: one row per
(commit, machine, demo, resolution) with three run columns and the median, plus
the raw `qconsole.log` per run. **Never wipe it mid-round.** Three runs, median
of runs 2 and 3.

Recovery for a wedged Mac: `ssh <machine> '~/bin/qsreboot.sh'`, then confirm it
cycles.
