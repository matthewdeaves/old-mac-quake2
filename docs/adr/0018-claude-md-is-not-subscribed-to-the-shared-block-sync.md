# 0018. CLAUDE.md is not subscribed to the shared block sync

Date: 2026-08-22

## Status

Accepted.

## Context

`old-mac-build-host/scripts/sync-shared-block.sh` keeps a "working alongside the
other repos" region identical across the seven repos. A repo opts in by wrapping
that region in `<!-- retro-shared-block -->` markers; canonical content lives in
`retro-agents/briefs/SHARED-BLOCK.md`. Everything between the markers is replaced
on the next `--write`, with no review by the repo being written into.

The problem it solves is real and measured. Before the tool existed the block was
hand-copied and had drifted to five distinct variants across seven repos, with
only the heading byte-identical in all of them. All four public ports said "five
repos" while the board spanned seven.

We adopted the markers in `d7591384`, then reverted them here.

## Decision

This repo's `CLAUDE.md` is maintained by hand and carries no sync markers.

## Consequences

The sync will report quake2 as "not adopted yet" forever. That is the intended
state, not an omission, and it is explicitly non-failing: the tool exits non-zero
on drift only.

Two reasons, and the second is the one that decided it.

**A synced region is a control change, not a content edit.** `CLAUDE.md` is this
repo's operating instructions, loaded into every session. Subscribing part of it
to unreviewed automatic overwrite from another repo hands a different tool silent
write access to how sessions here behave. The sync also writes straight into
working trees, which is how 122 lines of picker script reached a commit about
shellcheck earlier the same day, so a future session could commit canonical text
without anyone having read it.

That risk is not hypothetical. Canonical asserted something false about a repo
within four hours of being written: it told `retro-server-infra` that every
script driving a fleet machine re-execs under `scripts/pick-bench-host.sh`, and
that repo has no `scripts/` directory at all. It was caught only because that
repo was asked to trust it, and fixed in retro-agents `5a85e50`.

**Canonical converges on the weakest claim true of all seven.** Measured here
within an hour of adopting: the fix above put this repo in `DRIFTED`, and the
pending rewrite would have replaced

    Hardware is claimed, never assumed free. Every script that deploys to,
    benches on or otherwise drives a fleet machine re-execs under
    scripts/pick-bench-host.sh --run ... The lock is a directory on the target

with

    Shared things are claimed, never assumed idle. This fleet shares two kinds:
    the old Macs, and the live game servers.

The second is true of all seven and correct. It is also weaker for us. Driving
Mac hardware under a lock is most of what this repo does, and the specific
instruction naming the script, the flag and the lock's shape is worth more here
than a sentence generalised to accommodate a repo with no Macs. Any text that must
hold for seven repos will keep moving away from the four that are Mac ports.

Two things follow. The PUBLIC-versus-PRIVATE warning about `retro-server-infra`
can never be canonical at all, since two of the seven repos are private. And the
drift the tool exists to prevent is still ours to prevent by hand: when the fleet
rules change, this section is updated here, and `retro-agents/briefs/` wins where
the two differ, which the section says.

Nothing here objects to the tool. It is well built, its report mode is safe, and
a repo that wants the guarantee more than the specificity should adopt it.

## Addendum, 2026-08-22, same evening

Canonical acted on the second argument rather than disputing it. retro-agents
`62e1419` CUTS the hardware and `BENCH_NO_LOCK` paragraphs from the shared block
entirely, on the reasoning that shared text converges on the weakest claim and
each repo should keep that material in its own words. Canonical is down to 39
lines, and `grep` for `pick-bench-host` or `BENCH_NO_LOCK` in it now returns
nothing.

That weakens the convergence reason, honestly stated: the specific paragraphs
this ADR measured are no longer in canonical to converge. The pressure is
structural and still there for anything added later, but the scope is now much
smaller and the header warns against it.

The decision does not change, because the first reason is untouched: a synced
region is unreviewed automatic overwrite of the file governing how sessions here
behave.

Recorded here rather than by editing the text above, which is what was believed
and measured at the time.

## Addendum, second: what canonical had wrong about US

Cutting those paragraphs meant rewording them as ours, and both then turned out
to be false for this repo. We would have inherited both.

"The shared picker does not read `BENCH_NO_LOCK`" is wrong. `pick-bench-host.sh`
honours it in `cmd_run` at `:374` and prints a warning at `:296`;
`pick-build-host.sh` warns at `:187`.

"Every script that drives a fleet machine re-execs under
`scripts/pick-bench-host.sh --run`" is wrong here in a way that matters. Seven do.
`build.sh` and `build-fat.sh` claim with `pick-build-host.sh --acquire` and an
EXIT trap instead, because that picker has no `--run` mode at all (`:65`).
`parallel-bench.sh` claims nothing itself and delegates per leg to `bench.sh`.
`build-arm64.sh` and `build-server-linux.sh` touch no fleet machine.

`CLAUDE.md` now says that, checked against the scripts. The general point stands
on its own: the repo being written into is the only one that knows whether the
text is true of it.
