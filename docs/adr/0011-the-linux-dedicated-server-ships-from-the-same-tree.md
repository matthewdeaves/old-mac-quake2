# 11. The Linux dedicated server ships from the same tree, and is firewalled by allowlist

Date: 2026-08-20 (records decisions taken 2026-08-19 and 2026-08-20)
Status: accepted

## Context

The Mac clients are the fat binary's four slices (ADR 0001). A LAN game needs a
host, and a vintage Mac is a poor one. A headless x86_64 or aarch64 Linux box is
a good one, and the engine already builds there.

## Decision

**Build `q2ded` and `baseq2/game.so` for Linux from this same yquake2 5.11 tree,
in a Debian 11 container, and ship them as a tarball with a systemd unit.**

    scripts/build-server-linux.sh                 # x86_64
    scripts/build-server-linux.sh --arch aarch64  # ARM VPS

Needs Docker or Colima and nothing else. The container fixes the floor at
**glibc 2.31**, so the result runs on Ubuntu 20.04 and up, Debian 11 and up,
rather than depending on whatever the build machine happens to have. The only
shared libraries loaded are **glibc and zlib**, both part of a base install. No
renderer, no SDL, no audio.

**`game.so` is not optional and cannot be borrowed from the Mac release.** The
game logic runs server-side as native code for the server's CPU.

**`server.cfg` has to be in `baseq2/`**, not next to `q2ded`. Quake II's `exec`
searches the game directory, so a copy in the wrong place is never read and
never complains about it.

No game data ships (ADR 0012); the operator supplies `pak0.pak` and `pak1.pak`.

## The firewall is not optional, and here is the measured reason

This server answers **unauthenticated** status queries with far more than it was
asked for. Measured against this exact build:

| Query | Sent | Received | Amplification |
|---|---:|---:|---|
| `status` | 10 bytes | 228 bytes | **23x** |
| `info` | 11 bytes | 41 bytes | 4x |

**There is no rate limiting anywhere in the yquake2 server for these**, unlike
Quake III, which carries a leaky bucket. So anyone who can reach the port can
spoof your address as the source and have the box fire the replies at someone
else, under your IP. That is a DDoS reflector.

**An address allowlist fixes it completely**, because a spoofed packet claims to
come from the victim rather than from you, so the allowlist drops it. That is
why the shipped `ufw` rules are per source address rather than open to the
world. Where an allowlist is impractical, rate limit with `iptables
-m hashlimit` instead (recipe in `server/README.md`).

**`public 0` keeps the server off the master list**, so it appears in nobody's
in-game browser. **The `setmaster` console command sets `public 1` as its first
act, so running it once undoes that. Do not run it.**

Downloads are off deliberately: `allow_download` and its siblings push content
out to clients, and clients that already carry the same content from the same
release gain nothing, so leaving them on only ever serves a stranger.

## One remote overflow was found and fixed here

Fuzzing the out-of-band handler found a genuine remote crash. `SV_ReadPackets`
hands any connectionless packet to `SV_ConnectionlessPacket`, which tokenizes it
with no length cap, and `Cmd_TokenizeString` did

    strcpy(cmd_args, text);

where `cmd_args` is `MAX_STRING_CHARS`, **1024 bytes**, and `text` is attacker
controlled up to `MAX_MSGLEN`, **1400 bytes**. About **376 bytes past the end of
a static buffer, from one datagram**, before any client is accepted and with no
password involved. A **1204-byte `status` query carrying about 600 arguments**
took the server down on the **250th packet** of a run. Fixed in this tree the
way upstream fixed it, with a bounded copy, and verified against both the saved
crash corpus and a fresh run (commit `9b24e353`).

**What that implies matters more than the bug.** This build is 5.11 and upstream
is at **8.70** (ADR 0002). That gap is the real risk, and one bug found by a few
hours of fuzzing is not evidence that it is the only one. The firewall matters
here more than on any client machine.

The rcon password crosses the network in the clear. Use a long random one, do
not reuse it, and treat the box as disposable: the protocol underneath is from
1997 and has no encryption.

## Tuning for the clients that will actually connect

- The clients are `ppc750`, `ppc7400`, `ppc970` and `x86_64` from one app. There
  is **no `i386` slice**, so 32-bit-only Intel Macs are not covered, and **no
  `arm64` slice** (ADR 0001, ADR 0003).
- `timeout` is **125** rather than the default, because a vintage Mac stalling on
  a slow link should not be dropped for it.
- Fill `sv_maplist` with maps watched running on the oldest machine that will
  join, not on the fastest one.
- **Endianness needs nothing.** A little-endian Linux server talking to
  big-endian PowerPC clients is what the protocol already converts for.
- Connecting by name works everywhere: the engine resolves through
  `getaddrinfo`, on Panther as on macOS 26.

## Consequences

- Server and client share every engine fix, and every engine bug.
- The server is the only part of this project exposed to a network by design,
  so it is the only part where the 5.11 pin is a security decision rather than a
  compatibility one.
