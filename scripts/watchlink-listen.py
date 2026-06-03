#!/usr/bin/env python3
"""watchlink-listen.py -- desktop test harness for the in-engine watchlink feed.

Quake II's cl_watchlink.c emits newline-delimited JSON over UDP when the
`watch_host` cvar points at a listener. This script is that listener: run it,
point the game at it, and watch the marine's live vitals / events scroll past.
No dependencies beyond the Python 3 standard library.

Usage:
    python3 scripts/watchlink-listen.py [port]      # default port 27999

Then in the Quake II console (or an autoexec cfg):
    set watch_host "<this machine's IP>"     # e.g. 127.0.0.1 when testing locally
    set watch_port "27999"

A compact live status line is rendered in place for `vitals`; `event` and
`meta` packets are logged as they arrive. Ctrl-C to quit.
"""

import json
import socket
import sys


def fmt_vitals(d):
    pu = d.get("pu", {})
    pu_str = ""
    if pu.get("sec"):
        pu_str = f"  PU {pu.get('icon', '?')}:{pu['sec']}s"
    sel = d.get("sel") or "-"
    return (
        f"HP {d.get('hp', 0):>3}  "
        f"ARM {d.get('armor', 0):>3}  "
        f"AMMO {d.get('ammo', 0):>3}  "
        f"[{sel:<16.16}]  "
        f"frags {d.get('frags', 0)}{pu_str}"
    )


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 27999
    try:
        sys.stdout.reconfigure(line_buffering=True)  # survive redirection to a file
    except AttributeError:
        pass
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    print(f"watchlink: listening on udp/{port} (Ctrl-C to quit)\n")

    while True:
        data, addr = sock.recvfrom(4096)
        for raw in data.split(b"\n"):
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                print(f"  [unparsed] {raw!r}")
                continue

            kind = msg.get("t")
            if kind == "vitals":
                # redraw in place
                print("\r" + fmt_vitals(msg) + " " * 8, end="", flush=True)
            elif kind == "event":
                ev = msg.get("kind", "?")
                if ev == "centerprint":
                    print(f"\n>> {msg.get('msg', '')}")
                elif ev == "damage":
                    hit = [k for k in ("health", "armor", "ammo") if msg.get(k)]
                    print(f"\n!! DAMAGE ({', '.join(hit) or 'hit'})")
                else:
                    print(f"\n** event:{ev} {msg}")
            elif kind == "meta":
                items = msg.get("items", [])
                print(f"\n== MAP: {msg.get('level', '?')}  "
                      f"({len(items)} items known)")
            else:
                print(f"\n?? {msg}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nbye")
