# scripts/bundle/

Static assets staged into the `Quake2.app` bundle by `scripts/deploy.sh`,
plus the per-machine `autoexec.cfg` layer.

## Contents

| File | Role |
|---|---|
| `Info.plist` | CFBundle metadata. Read by Tiger/Panther/Lion/Sequoia Finder for icon + bundle recognition. |
| `set-bundle-bit.c` | C helper (HFS+ kHasBundle bit setter). Unused in current fleet — every Mac we ship to recognises `.app` by extension. Kept around in case a future HFS-volume target needs it. |
| `autoexec-<machine>.cfg` | Per-machine console-command stack, exec'd at engine boot. See below. |

## The autoexec layer

`yquake2` execs `<basedir>/baseq2/autoexec.cfg` once during `CL_Init`,
after `Cbuf_AddEarlyCommands` (cmdline `+set` sweep) and before
`Cbuf_AddLateCommands` (cmdline `+demomap` / `+map` / `+timedemo`). This
means **autoexec OVERRIDES any cvar set via `+set` on the engine command
line.** Deliberate consequences:

- `scripts/bench.sh` forces `+set gl_mode -1 +set gl_customwidth $W
  +set gl_customheight $H +set gl_swapinterval 0` for its per-res sweep.
  Per-machine autoexecs therefore **must not** touch those four cvars,
  or the bench's resolution control breaks. Resolution defaults live in
  `~/.yq2/baseq2/config.cfg` (persisted from the in-game video menu).
- Conversely, anything we DO set in autoexec sticks across launches —
  no need to also seed `config.cfg`.

### Per-machine config (not per-arch)

Unlike the sister QuakeSpasm project (which uses a `__VEC__`/`__ppc__`
compile-time dispatch in `host.c` to pick a per-arch autoexec), the
Q2 fat binary picks its tuning via `deploy.sh`'s `TARGET` argument:

| `deploy.sh` target | Machine | CPU | GPU | OS |
|---|---|---|---|---|
| `yosemite` | PowerMac1,1 (1999) | PPC 750 @ 449 MHz | ATI Rage 128 16 MB | 10.3.9 Panther |
| `sawtooth` | PowerMac3,1 (1999) | PPC 7400 @ 500 MHz | GeForce2 MX 32 MB | 10.4.11 Tiger |
| `quicksilver` | PowerMac3,5 (2001) | PPC 7450 @ 733 MHz | Radeon 9000 Pro 64 MB | 10.4.11 Tiger |
| `mini-g4` | PowerMac10,1 (2005) | PPC 7447A @ 1.25 GHz | Radeon 9200 32 MB | 10.4.11 Tiger |
| `mini-intel` | Macmini2,1 (2007) | Core 2 Duo @ 2.33 GHz | Intel GMA 950 64 MB | 10.7.5 Lion |
| `imac-2019` | iMac19,1 (2019) | i5-9600K @ 3.7 GHz | Radeon Pro 580X 8 GB | 15.7 Sequoia |

`deploy.sh <target>` (or `deploy.sh fat <target>`) copies
`autoexec-<target>.cfg` to `~/Desktop/quake2/baseq2/autoexec.cfg` on the
target machine. The same fat binary picks up a different autoexec on
each host — no engine-side CPU detection needed.

We did NOT mirror QS's per-arch autoexec scheme because the binary slice
is too coarse for Q2: mini-intel (GMA 950, integrated, weak) and
imac-2019 (Radeon Pro 580X, discrete, strong) share the x86_64 slice but
have completely different GPU envelopes. Per-machine selection in
`deploy.sh` cleanly separates them without a runtime CPU-detect hook.

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
