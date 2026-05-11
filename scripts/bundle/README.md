# scripts/bundle/

Static assets staged into the `Quake2.app` bundle by `scripts/deploy.sh`,
plus the per-machine `autoexec.cfg` layer that ships inside the bundle.

## Contents

| File | Role |
|---|---|
| `Info.plist` | CFBundle metadata. Read by Tiger/Panther/Lion/Sequoia Finder for icon + bundle recognition. |
| `set-bundle-bit.c` | C helper (HFS+ kHasBundle bit setter). Unused in current fleet — every Mac we ship to recognises `.app` by extension. Kept around in case a future HFS-volume target needs it. |
| `autoexec-<machine>.cfg` × 6 | Per-machine console-command stack, queued by the engine at boot via CFBundle. See below. |

## The autoexec layer

All six per-machine cfgs ship inside `Quake2.app/Contents/Resources/`.
The engine (`yquake2/src/common/misc.c:Qcommon_Init` → `Q2_ExecConfigFromBundle`)
reads the matching cfg at boot, layered AFTER the standard
`default.cfg` → `yq2.cfg` → `config.cfg` chain, so it always wins.
Machine identity is resolved at runtime via `sysctlbyname("hw.model", …)`:

| `hw.model` | Cfg picked | Machine |
|---|---|---|
| `PowerMac1,1` | `autoexec-yosemite.cfg` | PPC 750 @ 449 MHz, Rage 128 16 MB, Panther |
| `PowerMac3,1` | `autoexec-sawtooth.cfg` | PPC 7400 @ 500 MHz, GeForce2 MX 32 MB, Tiger |
| `PowerMac3,5` | `autoexec-quicksilver.cfg` | PPC 7450 @ 733 MHz, Radeon 9000 Pro 64 MB, Tiger |
| `PowerMac10,1` | `autoexec-mini-g4.cfg` | PPC 7447A @ 1.25 GHz, Radeon 9200 32 MB, Tiger |
| `Macmini2,1` | `autoexec-mini-intel.cfg` | Core 2 Duo @ 2.33 GHz, GMA 950 64 MB, Lion |
| `iMac19,1` | `autoexec-imac-2019.cfg` | i5-9600K @ 3.7 GHz, Radeon Pro 580X 8 GB, Sequoia |

This means **autoexec OVERRIDES any cvar set via `+set` on the engine
command line.** Deliberate consequences:

- `scripts/bench.sh` forces `+set gl_mode -1 +set gl_customwidth $W
  +set gl_customheight $H +set gl_swapinterval 0` for its per-res sweep.
  Per-machine autoexecs therefore **must not** touch those four cvars,
  or the bench's resolution control breaks. Resolution defaults live in
  `~/.yq2/baseq2/config.cfg` (persisted from the in-game video menu).
- Bench/screenshot scripts that need full cvar control can pass
  `-noarchautoexec` on the cmdline — the engine hook is gated on it.
- Anything we DO set in autoexec sticks across launches — no need to
  also seed `config.cfg`.

### Why bundle-Resources, not baseq2/autoexec.cfg

Previously the per-machine cfg was staged as `baseq2/autoexec.cfg` and
the engine picked it up via the gamedir filesystem (same flow as the
user's own autoexec). Two problems with that:

1. Mixed engine-shipped config with user game data — "drop the .app
   + your paks" wasn't actually enough; the deploy script also had to
   write into baseq2/.
2. The .app was no longer a self-contained distribution unit.

CFBundle resolves Resources/ relative to the executable's own image
path, so the bundle is the single unit of distribution. End users drop
`Quake2.app` + their own `baseq2/pak*.pak` next to each other; the
per-machine visual stack travels inside the .app.

### Why per-machine, not per-arch

Unlike the sister QuakeSpasm project (which uses both a `__VEC__`/`__ppc__`
compile-time per-arch baseline AND a per-machine overlay), Q2 only uses
per-machine. The binary slice is too coarse: mini-intel (GMA 950,
integrated, weak) and imac-2019 (Radeon Pro 580X, discrete, strong)
share the x86_64 slice but have completely different GPU envelopes.
Single-layer per-machine is enough.

### Design rationale per file

Every `autoexec-<machine>.cfg` opens with a header comment naming the
hardware and the design intent. Read the file directly for full context;
the short version:

| Machine | One-liner |
|---|---|
| `yosemite` | Strip everything the Rage 128 can't do cheaply (dlights, retex, alpha shadows) — claw back fps under the 20 fps floor. |
| `sawtooth` | Like yosemite but with 32 MB VRAM and slightly better GPU — same austerity, marginal trim of particle envelope. |
| `quicksilver` | Middle of the fleet, GPU-light CPU-bound — turn quality UP (retex, 4x AF, dlights, shadows). |
| `mini-g4` | Fastest PPC. Same quality stack as quicksilver; bumped maxfps. |
| `mini-intel` | Treat GMA 950 like a slightly-better R9200; never glFinish (Apple driver hates it). |
| `imac-2019` | 580X + 8 GB VRAM — max every 5.11-era knob. Phase B/C cherry-picks land here first. |

## Adding a new machine

1. Add a `case` to `deploy.sh` setting `HOST` + `BIN_TARGET`.
2. Create `scripts/bundle/autoexec-<newmachine>.cfg`. Start from the
   closest existing machine (by GPU class) and tweak.
3. Run `scripts/deploy.sh <newmachine>` — the autoexec stage step
   will pick up the new file automatically.

## Cvars audit

Every cvar referenced in these configs has been confirmed against the
yquake2 5.11 source tree (`grep -rn 'Cvar_Get' yquake2/src/`). We do
NOT invent cvars: anything not in the engine source is left out. Phase
B/C cherry-picks may introduce new cvars (e.g. `gl1_multitexture`,
`gl1_waterwarp`, `r_bloom`) — those land in the configs as their
backing code lands in `yquake2/src/`.
