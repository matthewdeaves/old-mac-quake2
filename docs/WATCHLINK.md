# watchlink — live player-state UDP feed

`src/client/cl_watchlink.c` pushes the marine's live in-game state out over UDP
as newline-delimited JSON, so an external companion (the planned Apple Watch
"tactical computer", or just `nc -ul` / `scripts/watchlink-listen.py`) can render
health / armor / ammo / inventory / objectives on a second screen.

**Off by default.** The whole feature is gated on the `watch_host` cvar: empty ⇒
no socket touched, no per-frame work, no packets. The default fleet build,
benchmarks and the DMG behave identically. This is a *runtime* opt-in, not a
load-time change (see MISTAKES.md on "zero-risk load-time" traps).

## Cvars

| cvar | default | meaning |
|---|---|---|
| `watch_host` | `""` | destination `ip` or `ip:port`; empty disables the feature |
| `watch_port` | `27999` | port used when `watch_host` omits one |
| `watch_rate` | `10` | vitals heartbeat, Hz (floored to ≥1ms interval) |
| `watch_events` | `1` | also emit discrete damage / centerprint events |

Set live from the console, or from an `autoexec-*.cfg`:

```
set watch_host "192.168.1.50"
```

## Wire format (newline-delimited JSON, UDP)

Endianness-proof on the big-endian PPC fleet; debuggable with `nc -ul 27999`.

```
{"t":"vitals","hp":87,"armor":50,"ammo":24,"sel":"Super Shotgun",
 "frags":3,"flashes":0,"layouts":0,"spec":0,"pu":{"icon":"p_quad","sec":18}}
{"t":"meta","level":"Outer Base","items":["Shotgun","Shells",...]}   // once per map load
{"t":"event","kind":"centerprint","msg":"You got the Railgun"}
{"t":"event","kind":"damage","health":1,"armor":1,"ammo":0}          // STAT_FLASHES rising edge
```

- **vitals** — throttled to `watch_rate` Hz from `cl.frame.playerstate.stats[]`.
- **meta** — level name (`CS_NAME`) + the owned-item name table (`CS_ITEMS`),
  sub-MTU so it never fragments; sent when the refresh is prepped (map load).
- **event/centerprint** — mirrors `SCR_CenterPrint` (pickups, objectives, story).
- **event/damage** — fired the instant `STAT_FLASHES` rises, for a wrist haptic.

## Integration points

- `CL_WatchLink_Init` — `cl_main.c` `CL_InitLocal` (registers cvars).
- `CL_WatchLink_Frame` — tail of `CL_Frame` (heartbeat + damage edge).
- `CL_WatchLink_Meta` — after `CL_PrepRefresh` in `CL_Frame`.
- `CL_WatchLink_CenterPrint` — inside `SCR_CenterPrint` (`cl_screen.c`).

Sends reuse the engine's existing non-blocking UDP client socket via
`NET_SendPacket`; no new socket is opened, and an unreachable `watch_host` never
stalls the frame.

## Desktop testing (Phase 0/1)

```
python3 scripts/watchlink-listen.py 27999      # in one terminal
# then in-game:  set watch_host "127.0.0.1"
```

The companion iPhone-relay + watchOS app design lives in the separate watch-app
repo / `quake2-watch-app-plan.md`.
