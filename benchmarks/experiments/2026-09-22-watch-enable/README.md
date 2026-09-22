# watch_enable: WatchLink off by default, one cfg toggle, 2026-09-22

User request: make WatchLink toggle on and off from a cfg file, and default it
to off. Before this change, ten bundle cfgs set `watch_host "auto"`, so every
launch on those machines ran Bonjour discovery for the companion.

## Change

- New archived cvar `watch_enable`, default `0`. WatchLink sends nothing and
  runs no discovery unless it is `1`. Toggling it live reconciles the same way
  as a `watch_host` edit, so turning it off stops discovery in flight.
- `game.so`'s objectives mirror (`view.c`) checks the same cvar.
- The bundle cfgs keep `watch_host "auto"` and never set `watch_enable`. They
  execute after `config.cfg`, so setting it there would reset the player's
  choice on every launch. To turn it on, put `set watch_enable 1` in
  `~/.yq2/baseq2/config.cfg`, or type it at the console.

## Test, workstation (Apple M5, macOS 26.6.2, arm64)

Setup: a scratch copy of the installed v2.12.0 app under
`~/oldmac/quake2/watch-test`, with game data symlinked and `/Applications`
untouched. The new build was the thin arm64 output of `scripts/build-arm64.sh`
(source stamp `68a3dba054e9`, engine MD5 `cffe3d0068b6fb905c635d6a160ba0e8`,
game.so `59efc3748a4ef0d2b781feceff4a3c3f`). The old build was v2.12.0
(engine `2f7874dd…`).

Each run: production bundle cfgs, windowed, `s_initsound 0`, `+map base1`,
killed after 20 s. A UDP listener on `127.0.0.1:27999` ran for 24 s. The
user's `config.cfg` was restored after each run (`cmp` identical). Script:
`run.sh`.

| Case | Build | Extra args | UDP packets | WatchLink log |
| --- | --- | --- | --- | --- |
| A0 | v2.12.0 | none | 0 | browsing, then "no companion found" |
| A | new | none | 0 | none |
| B | new | `watch_enable 1`, `watch_host 127.0.0.1:27999` | 20 (18 vitals, 2 event) | streaming to 127.0.0.1:27999 |
| B-old | v2.12.0 | `watch_host 127.0.0.1:27999` | 24 (20 vitals, 4 event) | streaming to 127.0.0.1:27999 |
| C | new | `watch_enable 1` | 0 | browsing, then "no companion found" |

Result: off by default (A against the control A0). Turning it on restores
both the fixed-address stream (B) and the auto-discovery path (C).

Two limitations:
- The packet counts depend on how far into gameplay each run got, so they
  aren't a comparison.
- A live console toggle mid-session wasn't exercised. Only the launch-time
  setting was tested.

## Pre-existing gap found, not changed here

Neither build sends the `meta` packet (level name and item table) on a normal
`+map` load. `CL_WatchLink_Meta` is called only from the delayed-precache
branch in `cl_main.c`, not from `CL_PrepRefresh`'s normal call sites
(`cl_download.c:417`, `cl_main.c:460`).
