# Bench row provenance: what a results.csv row cannot say

Proposal and gap list for `benchmarks/results.csv` rows (from the 2026-08-23 read of `bench.sh` at `45ca55f0`). Three things a row hides: vsync state, overridden cvars, the baseline config. A proposed richer row and the two anti-fabrication guards to keep are below. For running benches see `docs/BENCH.md`; for job concurrency see `docs/JOBS.md`.

## Current header

`bench.sh:259`:

    timestamp,commit,build_type,machine,cpu,gpu,os,demo,res,
    run1_fps,run2_fps,run3_fps,median_fps,notes

## What a row cannot say

1. **vsync is forced off and no column says so.** `bench.sh:301` hardcodes `+set gl_swapinterval 0`. The engine default is 1 and no bundle layer sets it for any PowerPC machine. Every PowerPC row is a number no player has seen. Measured on mini-g4: 41.10 vsync off, 29.90 on. Both are "the mini-g4 result" and the file cannot tell them apart.
2. **Overridden cvars land in prose.** `EXTRA` is appended to `notes` (:243, :252), commas rewritten to semicolons, truncated at 240 chars (:254): captured, but not queryable and silently lossy.
3. **The baseline is not recorded.** `bench.sh` does not pass `-noarchautoexec`, so the shipped overlay and the machine's archived `config.cfg` are both live under the cmdline `+set`. `commit` makes the overlay derivable; the archived config is derivable from nothing.

## Proposed row

As a job these are recorded automatically instead of by a human remembering to set NOTES:

    timestamp, commit, build_type, machine, cpu, gpu, os, demo, res,
    vsync,            0 or 1, explicit, never inferred
    cvar_overrides,   structured k=v, not prose, not truncated
    config_sha,       sha of the machine's config.cfg at run time
    overlay,          which autoexec-<machine>.cfg was in effect
    timeout_s, runs,
    run1_fps..runN_fps, median_fps, spread_fps,
    outcome,          OK | TIMEOUT | FAILED, never blank
    notes

`spread_fps` matters as much as the median: a mean and a median-of-runs-2-and-3 disagreed in sign on the same three-run data at a 3 fps spread. `outcome` splits the three states the schema collapses into `NA`: finished, ran out of time, or failed. Only the first is a measurement. A timeout expiring says the run did not finish in the time allowed and nothing else; timeouts must be job parameters, not the constants at `bench.sh:177-187`.

## Guards to keep

`bench.sh` already defeats stale-log fabrication: it deletes `~/.yq2/baseq2/qconsole.log` before each run (:292) and writes `NA` when no fps line appears (:340). Keep both. A job reusing a fixed output path that carries on after a failed fetch will parse the previous run's number and emit a complete, plausible, fabricated row.
