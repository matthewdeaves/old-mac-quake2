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
scripts/bench-evidence.sh <machine> <round-label> [--requested k=v,...]  # one evidence bundle
scripts/bench-compare.sh --baseline B... --candidate C...                # verdict from bundles
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
  1440x900. **ADR 0008, never bypass this.**
- **`yosemite` / `yosemite-tiger`** are one machine on one IP with two OS
  partitions, only one booted at a time. `parallel-bench.sh` refuses to run both
  legs. Switch with
  `ssh yosemite 'sudo bless --mount "/Volumes/<vol>" --setBoot'` then reboot with
  plain `sudo /sbin/reboot </dev/null`, **not** `sudo -n`, which Tiger's and
  Panther's sudo 1.6.x reject outright.
- Every run is TERM, sleep, KILL. Never a bare KILL.
- A malformed resolution is rejected rather than benched.

## Evidence bundles (build-host#104)

`scripts/bench-evidence.sh <machine> <round-label> [--requested k=v,...]`
drives ONE run through `scripts/bench-adapter.sh` (this port's own,
port-owned wrapper around `bench.sh`) and captures a bundle under
`~/oldmac/evidence/quake2/<UTC-stamp>/` on the workstation: `meta.json`,
`log.txt`, `stats.txt`/`stats.unit`, `effective.txt`, `requested.txt`,
`verdict.txt` (`VALID` or `INVALID: <reasons>`). Exit 0 valid, 1 invalid, 2
usage/config. Full contract: `old-mac-build-host/docs/bench-evidence.md`.

Required env: `BENCH_ARTEFACT=<path to the local binary matching what's
installed on the target>` (hashed on the workstation and compared against
the installed binary — mismatch is INVALID, not "not checked"; PPC builds
are not byte-reproducible, so this must be the exact deployed bits, e.g.
extracted from the promoted DMG, not a fresh local build), `BENCH_RES=<WxH>`
(forwarded to `bench.sh`'s own required resolution arg and its imac-g5
native-mode guard), optionally `BENCH_DEMO` (default `demo1`).

Because this adapter is synchronous (`bench.sh` always blocks until the run
finishes), the bundle's frame-capture and liveness checks are always "not
checked" here, never a false VALID/INVALID — this is expected, not a gap
(build-host#109).

Run several rounds back-to-back (a shell loop, one `bench-evidence.sh` call
per round) to separate cold-start effects or intermittent GPU variance from
a real trend; the CSV path (`bench.sh` itself) only ever keeps 3 run columns
per invocation, so a 4+-round variance check belongs here, not there.

`scripts/bench-compare.sh --baseline <bundle...> --candidate <bundle...>`
prints the verdict to quote (`BETTER`/`WORSE`/`INCONCLUSIVE`) from two or
more bundles' `stats.txt`. Needs 2+ rounds per side for its cold-start
discard to fire (build-host#114) — a single round per side reads a
confident verdict off of pure noise.

## Results

`benchmarks/results.csv` is the canonical numeric record: one row per
(commit, machine, demo, resolution) with three run columns and the median, plus
the raw `qconsole.log` per run. **Never wipe it mid-round.** Three runs, median
of runs 2 and 3.

Recovery for a wedged Mac: `ssh <machine> '~/bin/qsreboot.sh'`, then confirm it
cycles.
