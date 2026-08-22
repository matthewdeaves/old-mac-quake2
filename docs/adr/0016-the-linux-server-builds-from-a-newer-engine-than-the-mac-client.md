# 16. The Linux server builds from a newer engine than the Mac client

Date: 2026-08-22
Status: accepted. Supersedes the "same tree" half of [ADR 0011](0011-the-linux-dedicated-server-ships-from-the-same-tree.md); the rest of 0011 stands.

## Context

ADR 0011 built the Linux dedicated server from the same yquake2 5.11 tree as the
Mac clients, so it was protocol-identical to them **by construction**. That was
the right call at the time and it removed a whole class of doubt.

The cost has grown. 5.11 is from 2013 and upstream is at 8.70. Everything fixed
in between is absent from the one process here that faces the internet, and
that is no longer theoretical:

- **A remote overflow** was found locally by fuzzing: an unbounded `strcpy` in
  `Cmd_TokenizeString`, reachable from an unauthenticated `status` query with no
  connection. Fixed here, and fixed upstream long ago. One bug found by a few
  hours of fuzzing is not evidence it is the only one.
- **A real outage**, [#13](https://github.com/matthewdeaves/old-mac-quake2/issues/13).
  A timelimit rotation on a map outside `sv_maplist` issued `gamemap ""`. The
  engine shut the game down and the process stayed alive with its port bound,
  while `systemctl` reported it `active`. Six minutes of outage that looked
  exactly like health.

The Mac client pin cannot move. 5.11 is why the PowerPC slices work at all
(ADR 0002), and nothing about that has changed.

But the client and the server do not have to be the same tree. **They have to be
protocol compatible**, and Quake II protocol 34 is stable across this range.

## Decision

**The Linux dedicated server builds from `yquake2-server/`, a flattened
yquake2 8.70, plus this port's own server fixes. The Mac client keeps building
from `yquake2/` at 5.11.**

`scripts/build-server-linux.sh` stages `yquake2-server/`. Nothing else changes:
same container, same glibc 2.31 floor, same tarball, same systemd unit.

### Proven, not assumed

ADR 0011's guarantee was "identical by construction". This replaces it with a
weaker but real guarantee: **compatible by measurement**. That is a genuine
downgrade in certainty and is the main cost of this decision.

The measurement, taken twice, once against stock 8.70 and once against the
built server with our changes in:

```
PPC_G5 connected                 dual PowerMac G5, 10.5.8, our 5.11 client
PPC_G5 entered the game
0 20 "PPC_G5"                    score 0, ping 20ms, in the player table

G3_PPC connected                 Power Mac G3, 10.3.9, our 5.11 client
G3_PPC entered the game
```

Not a handshake and not a status reply: clients that loaded the map, spawned,
and were served, on two different PowerPC machines a decade apart in age.

### Three fixes carried forward

Upstream does not have these, so a naive bump would reintroduce bugs already
fixed here:

| Fix | Why upstream does not cover it |
|---|---|
| `setvbuf` on the Unix path (#11) | 8.70 line buffers stdout in the **Windows** backend only |
| Connectionless query rate limiter | Upstream has none at all |
| `ExitLevel` empty-changemap guard (#13) | Still absent in 8.70 |

**Dropped deliberately:** our bounded `Cmd_TokenizeString`. Upstream fixed that
between 5.11 and 8.70, so carrying ours would duplicate a fix already present.

### Flattened, not submoduled

Matches how `33200384` vendored 5.11. Upstream is carried whole, so `git log` on
the tree is our work and nothing else, and there is no build-time patching to
drift. Costs about 9 MB.

## Consequences

- **Two engine trees in one repo.** `yquake2/` is the client at 5.11,
  `yquake2-server/` is the server at 8.70. Anyone editing server code must
  edit the second, and a fix that belongs in both has to be made twice. That is
  the price of the split and it is deliberate: the alternative is one tree that
  is wrong for one of the two targets.
- **Protocol compatibility is now a test, not a property.** It must be re-run
  on any future server bump, with a real PowerPC client. A status reply is not
  sufficient evidence; the client has to spawn and be served.
- The Mac client is untouched by this decision. Its releases and its pin are
  unaffected.
- Upstream security fixes from 2013 onward now reach the internet-facing
  process, which is the whole point.

## Alternatives rejected

**Bump the whole repo to 8.70.** Breaks the PowerPC clients, which is the
project. Not viable.

**Stay on 5.11 and lean on the firewall.** The allowlist is real and stays
either way, but it does not fix a bug reachable from an allowed peer, and #13
was not an attack. It was a timelimit.

**A git submodule or a fetch-at-build-time pin.** Both reintroduce a moving part
at build time. ADR 0012 in the Half-Life port moved deliberately away from
patching a tree on the way to the compiler, and this repo already vendors
flattened source. Consistency wins.

**Fork yquake2 and carry our commits on a branch.** How the Half-Life port
handles its five upstreams. Rejected here only because this repo has no such
fork and vendors flattened source already; changing both at once would mix two
decisions.
