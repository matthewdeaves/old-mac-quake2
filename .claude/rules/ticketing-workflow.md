## Working alongside the other repos

This repo is one of seven worked on together: four game ports,
`retro-server-infra` which runs the servers, the private `old-mac-build-host`
which owns the machines, and `retro-agents` which runs the sessions. One board
covers all seven: <https://github.com/users/matthewdeaves/projects/8>.

**Hardware is claimed, never assumed free.** The lock is a directory on the
target, so it is shared with the build lock and visible to every repo, agent and
workstation. Check `scripts/pick-bench-host.sh --status` before
assuming a box is idle and NEVER work around a busy one.

Neither picker is a copy in this repo any more (build-host#105's pin model,
`shared-scripts.pin`, ADR 0007 in old-mac-build-host) — both are fetched
on demand via `scripts/shared.sh <name>.sh [args...]` from a sibling
`../old-mac-build-host` checkout (`OLDMAC_BUILDHOST_REPO` overrides).
`pick-bench-host.sh` is still callable at this same path, though: it's a
thin shim (`exec`s through `shared.sh`) kept in place because
old-mac-build-host's generated Jenkins jobs invoke it by fixed path
(build-host#119, halflife#49). `pick-build-host.sh` has no such caller and
is genuinely gone — reach it as `scripts/shared.sh pick-build-host.sh ...`.

Two pickers, and they claim differently. Seven scripts re-exec themselves under
`pick-bench-host.sh --run` (the shim above), which ties the lock to the
invocation so it is released however the run ends: `bench.sh`, `deploy.sh`,
`deploy-dmg.sh` (also a shim), `make-dmg.sh`, `screenshot.sh`, `smoke-dmg.sh`
(also a shim), `tidy-quicksilver.sh`. `build.sh` and `build-fat.sh` instead
claim a build mini with `scripts/shared.sh pick-build-host.sh --acquire` and
release on an EXIT trap, because that picker has no `--run` mode at all.
`parallel-bench.sh` claims nothing itself; each leg is a `bench.sh` call
that claims its own machine, and its reachability probe is left unclaimed
on purpose. `build-arm64.sh` and `build-server-linux.sh` touch no fleet
machine, running on the workstation and in Docker.

`BENCH_NO_LOCK=1` exists only for debugging the picker itself, and it is not an
escape hatch for a busy machine. `pick-bench-host.sh --run` honours it and says
so loudly on stderr; `--acquire` always claims and only warns that the
variable is set. The build picker never honours it. Line numbers into either
picker are no longer meaningful here — both live in old-mac-build-host now,
at whatever revision `shared-scripts.pin` names.

Nothing arbitrates WORKING TREES. Two sessions in one repo can collide silently,
and a sync can write into your tree mid-task, so stage by name and never
`git add -A`.

**The board columns are gates, not labels:**

    Triage -> Measuring -> Ready -> In progress -> Blocked -> Review -> Done

`Triage` is the user's gate; only a human moves work out of it. `Measuring` means
approved: work it. **Close your own tickets once fixed and tested.** Evidence in
a closing comment on the issue, then move it to `Done` yourself (`user,
2026-09-22`, `retro-agents/POLICY.md:47`). Still never write `Closes #12`
or `Fixes #12` in a commit message: GitHub acts on those immediately, which can
close an issue before its evidence comment is posted or before an unrelated
commit means to touch it at all. Write `Refs #12` in commits, then close the
issue and move the board column as a separate, deliberate step once the
evidence is in place.

Filing an issue does NOT put it on the board and nothing sets a status on a new
item, so it lands in no column at all and looks like work nobody raised. Run
`retro-agents/bin/board-add.sh <repo>#<n>` after filing, every time.

**The full rules are in `retro-agents/briefs/`, not here.** Every session is
launched with them. This is the short version for a human reading this repo
cold; where the two differ, the briefs win.

This section is maintained BY HAND and is deliberately not subscribed to
`old-mac-build-host`'s block sync. See `docs/adr/0018`.

## Filing across repos

File cross-repo work as an issue, WITHOUT `--project`, then put it on the board:

```sh
gh issue create -R matthewdeaves/<repo> \
  --label from:port,needs-measurement --title "..." --body "..."
../retro-agents/bin/board-add.sh <repo>#<n>     # adds it AND sets Triage
```

Not `--project Retro`: it adds the item with Status null, so the ticket is not
in the wrong column, it is in NO column. Filing alone does not put an issue on
the board at all.

The board also carries `Source` and `Evidence` fields.

Labels, the same four in every repo: **`from:infra`** raised by the server side
for a port to act on, **`from:port`** raised by a port for another repo,
**`needs-measurement`** the claim has no number or hardware repro behind it yet,
**`cross-port`** it affects more than one port, so expect sibling issues.

**Anything one session raises at another starts in `Triage` with
`needs-measurement`, and is not worked until a human or a measurement moves it.**
An issue written by another agent carries no more evidence than the reasoning
that produced it, and it arrives looking exactly like one backed by a bench run.
That gate is the whole reason the board has a `Measuring` column. The same
finding really does recur across ports (the PowerPC SDL2 `--disable-joystick`
issue was filed in three repos on the same day), so `cross-port` is worth using,
but file the sibling issues rather than assuming the fix transfers.

**This repo is PUBLIC. `retro-server-infra` is public too, as of 2026-08-31
(confirmed intentional, not an accidental toggle — was private since
2026-07-28 over an upstream dispute).** It describes the topology, firewall
rules and admin surface of a live host, so the caution stands regardless of
its own visibility: never copy addresses, key material, tunnel tokens or
`.env` content out of it into this repo, in code, docs or a commit message.
Referring to a server release tag is fine; describing
where it runs is not.
