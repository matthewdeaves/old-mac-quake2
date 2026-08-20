# scripts/bundle/

Static assets staged into `Quake2.app` by `scripts/deploy.sh` and
`scripts/make-dmg.sh`.

The layering model, the call-site constraint, the machine map and the
comment-stripping rule are all in **ADR 0007**. Cvar meanings and per-machine
values are in `docs/CONFIG.md`.

| File | Role |
|---|---|
| `Info.plist` | CFBundle metadata. Read by Panther, Tiger, Leopard, Lion and modern Finder for icon and bundle recognition. `deploy.sh` / `make-dmg.sh` stamp the version from `git describe` |
| `autoexec-controls.cfg` | layer 0: shared WASD + mouse-look, overriding stock yquake2's ESDF layout |
| `autoexec-ppc750/ppc7400/ppc970/x86_64.cfg` | layer 1: per-arch baseline, selected at **compile** time. The floor that makes any G3/G4/G5/Intel Mac playable, not just the bench boxes |
| `autoexec-<machine>.cfg` x 8 | layer 2: per-machine overlay, selected at **runtime** by `hw.model` |
| `set-bundle-bit.c` | HFS+ `kHasBundle` bit setter. Unused, every Mac shipped to recognises `.app` by extension. Kept for a future HFS-volume target |

## Design intent per machine

Read the header comment in each cfg for the full context. The short version:

| Machine | Intent |
|---|---|
| `yosemite` | strip everything the Rage 128 cannot do cheaply, then spend the reclaimed budget on the ULTIMATE texture/filter/shadow/fog stack (ADR 0010) |
| `sawtooth` | yosemite's austerity with 32 MB VRAM; dlights off, billboard halos instead |
| `quicksilver` | middle of the fleet, GPU-light and CPU-bound, quality up |
| `mini-g4` | fastest PPC; quicksilver's stack with a higher maxfps |
| `imac-g5` | most-capable PPC tune at native 1440x900. **Also a safety entry**, the overlay's `vid_desktopfullscreen` is what stops the baseline's 1024x768 becoming a mode switch the R300 cannot survive (ADR 0008) |
| `imac-g4` | **untested, no such machine here.** Built on the sawtooth floor, pinned at 1024x768 |
| `mini-intel` | treat the GMA 950 as a slightly better R9200; never `glFinish`, the Apple driver hates it |
| `imac-2019` | 580X with 8 GB, max every 5.11-era knob; new cherry-picks land here first |

## Adding a machine

1. Add a `case` to `deploy.sh` setting `HOST` and `BIN_TARGET`.
2. Create `autoexec-<newmachine>.cfg`, starting from the closest existing
   machine by GPU class.
3. Add the `hw.model` string to the map in `yquake2/src/common/misc.c`.
4. Run `scripts/deploy.sh <newmachine>`; the staging step picks the file up.
5. Bench it before setting any default (ADR 0010).
