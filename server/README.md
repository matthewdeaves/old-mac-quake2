# Quake II dedicated server, Linux

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

## Connecting

From the Mac client:

```
connect your.server.address
```

If a password is set, `set password "..."` on the client first. Nothing else
about the client differs for internet play. The server is little-endian and
the PowerPC clients are big-endian; that is the same arrangement the Mac
builds already handle on a LAN.

## Building it yourself

```sh
scripts/build-server-linux.sh                 # x86_64
scripts/build-server-linux.sh --arch aarch64  # ARM VPS
```

Needs Docker or Colima and nothing else. The build runs in a Debian 11
container so the result depends on glibc 2.31 rather than on whatever the
build machine happens to have.
