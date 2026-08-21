# Quake II dedicated server: Linux

A headless Quake II server built from the same yquake2 tree as the Mac fat
binary. No packages to install.

## What is in the tarball

```
q2ded                        the server engine
baseq2/game.so               the game logic, which runs server side
server.cfg                   configuration, goes in baseq2/
systemd/q2ded.service
BUILD-INFO.txt               what this was built from
```

No game data. Quake II's content is id Software's and is not ours to ship. You
supply `baseq2/pak0.pak` and `baseq2/pak1.pak` from your own copy.

`game.so` is not optional and cannot be borrowed from the Mac release: the
game logic runs on the server, as native code for the server's CPU.

### `game.so` has no architecture in its name, and that will bite you

Quake II calls the game library plain `game.so` on every platform. The x86_64
copy and the aarch64 copy are the same filename, so one will silently replace
the other, and `baseq2/` holds both game content and this library, so any rsync
of "the content directory" between two machines moves it too.

When the wrong one lands, the engine says:

```
LoadLibrary (/opt/quake2-server/baseq2/game.so): cannot open shared object file: No such file or directory
```

which is the loader's way of saying **wrong architecture**. The file is plainly
there with the right owner and permissions, so the message points nowhere near
the actual problem. `file baseq2/game.so` is what settles it:

```sh
file /opt/quake2-server/baseq2/game.so     # want: ELF 64-bit ... x86-64  (or aarch64)
uname -m                                   # want: the same
```

The failure is quiet in every other respect. The unit stays `active`, the UDP
socket binds and shows in `ss`, and the server answers nothing while burning
100% of a core in a `pselect6` loop.

So: copy content between machines with `--exclude game.so`, and re-check it
after any move. Half-Life avoids this by naming its libraries `hl_amd64.so` and
`hl_arm64.so` so both can coexist; renaming here would mean engine changes, so
the warning is the fix.

## Requirements

Any Linux with glibc 2.31 or newer, so Ubuntu 20.04 and up, Debian 11 and up.
The only shared libraries loaded are glibc and zlib, both part of a base
install. No renderer, no SDL, no audio.

## Install

```sh
sudo useradd --system --home /opt/quake2-server --shell /usr/sbin/nologin quake2
sudo mkdir -p /opt/quake2-server/baseq2
sudo tar xzf quake2-server-*-linux-x86_64.tar.gz --strip-components=1 \
     -C /opt/quake2-server
sudo cp /opt/quake2-server/server.cfg /opt/quake2-server/baseq2/server.cfg

# your own copy of the game
sudo cp pak0.pak pak1.pak /opt/quake2-server/baseq2/

sudo chown -R quake2:quake2 /opt/quake2-server
sudo cp /opt/quake2-server/systemd/q2ded.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now q2ded
```

`server.cfg` has to be in `baseq2/`, not next to `q2ded`. Quake II's `exec`
searches the game directory, so a copy in the wrong place is never read and
never complains about it.

Set `password` and `rcon_password` in `server.cfg` before you expose the port.

## Changing the map

Two ways.

**From inside the game**, if `rcon_password` is set. On any client:

```
set rcon_password "your-password"
set rcon_address your.server.address:27910
rcon gamemap q2dm2
rcon status
```

You can bind that to a key, so changing map on a G4 is one keypress:

```
bind F6 "rcon gamemap q2dm2"
```

The rcon password crosses the network in the clear, so use a long random one
and do not reuse it anywhere else.

**From the server**, through the FIFO the systemd unit sets up:

```sh
echo "gamemap q2dm2" | sudo tee /run/quake2-server/console
echo "status"        | sudo tee /run/quake2-server/console
journalctl -u q2ded -f
```

`sv_maplist` in `server.cfg` handles rotation on its own when a time or frag
limit is hit.

## The network side

Default port is UDP 27910.

```sh
sudo ufw allow from <their.ip.here> to any port 27910 proto udp
sudo ufw allow from <your.ip.here>  to any port 27910 proto udp
```

The server is not advertised: `public 0` keeps it off the master list, so it
appears in nobody's in-game browser. One thing to know is that the `setmaster`
console command sets `public 1` as its first act, so running it once undoes
that. Do not run it.

Between the join password and the firewall this is a genuinely private server,
but the protocol underneath is from 1997 and has no encryption. Treat the box
as disposable and do not co-host anything you care about.

### The firewall is not optional, and here is the measured reason

This server answers unauthenticated status queries with far more than it was
asked for. Measured against this exact build:

| Query | Sent | Received | Amplification |
|---|---|---|---|
| `status` | 10 bytes | 228 bytes | **23x** |
| `info` | 11 bytes | 41 bytes | 4x |

There is no rate limiting anywhere in the yquake2 server for these, unlike
Quake III which carries a leaky bucket. So anyone who can reach the port can
spoof your address as the source and have your box fire the replies at someone
else, under your IP. That is a DDoS reflector.

An address allowlist fixes it completely: a spoofed packet claims to come from
the victim, not from you, so the allowlist drops it. That is why the `ufw`
rules above are per source address rather than open to the world.

If an allowlist is impractical, rate limit instead:

```sh
sudo iptables -A INPUT -p udp --dport 27910 \
  -m hashlimit --hashlimit-name q2-query --hashlimit-above 10/sec \
  --hashlimit-burst 20 --hashlimit-mode srcip -j DROP
```

### One remote overflow was found and fixed here

Fuzzing the out-of-band handler found a genuine remote crash in this engine: a
`status` query of about 1200 bytes overflowed `cmd_args`, a 1024-byte static
buffer, through an unbounded `strcpy` in `Cmd_TokenizeString`. No password and
no connection were needed. It is fixed in this tree the way upstream fixed it,
with a bounded copy, and verified against both the saved crash corpus and a
fresh run.

Worth knowing what that implies: this build is yquake2 5.11 and upstream is at
8.70. That gap is the real risk, and one bug found by a few hours of fuzzing
is not evidence that it is the only one. The firewall matters here more than
on the other three.

## Connecting

From the Mac client:

```
connect your.server.address
```

If a password is set, `set password "..."` on the client first.

Connecting by name works everywhere: the engine resolves through
`getaddrinfo`, so point an A record at the box and that name is all either of
you types. It behaves the same on Panther as on macOS 26.

## Tuned for the machines that will actually connect

The clients are the fat binary: `ppc750`, `ppc7400`, `ppc970` and `x86_64`
from one app. The oldest of those is what the config is aimed at. Note there
is no `i386` slice, so 32-bit-only Intel Macs are not covered, and no `arm64`
slice yet.

`timeout` is 125 rather than the default, because a vintage Mac stalling on a
slow link should not be dropped for it. `sv_maplist` is worth filling with
maps you have actually watched run on the oldest machine that will join,
rather than on the Apple Silicon one where everything is fast.

Endianness needs nothing from you. A little-endian Linux server talking to
big-endian PowerPC clients is the arrangement the Mac builds already handle,
and the protocol does the conversion.

The downloads settings are off deliberately. `allow_download` and its
siblings push content out to clients, and both of your clients already carry
the same content from the same release, so leaving them on only ever serves a
stranger.

## Building it yourself

```sh
scripts/build-server-linux.sh                 # x86_64
scripts/build-server-linux.sh --arch aarch64  # ARM VPS
```

Needs Docker or Colima and nothing else. The build runs in a Debian 11
container so the result depends on glibc 2.31 rather than on whatever the
build machine happens to have.
