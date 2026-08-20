# 7. Bundle config is three layers: applied before the renderer initialises

Date: 2026-08-20 (records decisions taken 2026-05-31)
Status: accepted

## Context

One `.app` has to auto-tune for a Rage 128 G3 on Panther, three different G4
GPUs on Tiger, an R300 G5 on Leopard, a GMA 950 on Lion and a Polaris iMac on
Sequoia, and has to be a self-contained drag-and-drop unit next to the user's own
`baseq2/pak*.pak`.

## Decision

**Ship the configuration inside `Quake2.app/Contents/Resources/` and execute it
in three layers, all of them before `CL_Init()` / `VID_Init`.** Implementation:
`yquake2/src/common/misc.c`, `Q2_ExecConfigFromBundle` and its call site in
`Qcommon_Init`.

- **Layer 0, shared controls** (`autoexec-controls.cfg`): machine-independent
  WASD + mouse-look, overriding stock yquake2's ESDF layout. Execed first.
- **Layer 1, per-arch baseline** (`autoexec-ppc750` / `ppc7400` / `ppc970` /
  `x86_64`.cfg): selected at **compile** time, so the baseline baked into the
  slice dyld picked is the one that runs. This is the floor that makes the game
  playable on **any** G3/G4/G5/Intel Mac, not just the bench boxes.
  **`Q2_ARCH_PPC970` must be checked first**, the 970 slice also defines
  `__VEC__`, so without the explicit build macro it falls into the ppc7400
  branch (ADR 0001).
- **Layer 2, per-machine overlay** (`autoexec-<machine>.cfg`): selected at
  **runtime** via `sysctlbyname("hw.model", …)`, layered after the baseline so
  it wins on known boxes. Unknown models keep just Layer 1.

Later layers override earlier ones because each appends to `Cbuf` in order.

## The call site is load-bearing

The block sits in `misc.c` right after `Cbuf_AddText("exec config.cfg\n")` and
**before `Cbuf_AddEarlyCommands(true)`**, which is before `SV_Init()` /
`CL_Init()`.

- The cfgs use **`set CVAR VALUE`**, not bare `CVAR VALUE`. Q2's parser routes a
  bare assignment through `Cvar_Command`, which **ignores unknown cvars**;
  `set` creates the cvar on demand. So renderer cvars created here are picked up
  unchanged by `ref_gl`'s `Cvar_Get` when it lazy-loads, exactly as the saved
  `config.cfg` already reaches the first init. There is no need to wait for
  `ref_gl.so`.
- The video cvars are therefore set **before `VID_Init` loads the renderer**, so
  it comes up in the final mode on the first frame with **no refresh-DLL
  reload**, and per-machine defaults apply on the **first** launch.
- `+set` from the command line is an early command applied just after this
  block, so bench scripts still override it and benchmarks stay deterministic.

### Root cause this placement fixes (v2.2.3)

With the cfgs applied **after** `CL_Init`, their `vid_fullscreen 1` / `gl_mode
-1` changed the mode post-init. `R_BeginFrame` (`r_main.c`) escalates a post-init
mode change into a full refresh-DLL reload: it sets `vid_ref->modified`, and the
next `VID_CheckChanges` tears down and reloads `ref_gl.so` via `VID_LoadRefresh`.
On the ATI Rage 128 / Panther G3 that reload path is fatal,
`Com_Error → VID_Shutdown → R_Shutdown → GLimp_Shutdown → SDL_GL_SwapBuffers` on
a torn-down context → `EXC_BAD_ACCESS`. The menu came up, then **"start a new
game" hard-crashed the G3** on the first rendered world frame.

Two things had masked it: `+set` is an early command, so bench runs never
tripped it; and an earlier validation on the G3 used `+set vid_fullscreen 0`,
which net-cancelled the cfg's `vid_fullscreen 1`, so no mode change and no
reload.

Defence in depth: `GLimp_Shutdown` (`refresh.c`) now guards its cosmetic
backbuffer clear and swap on a live `surface`, so a future reload cannot
re-crash on a stale context.

**Rule: on this SDL-1.2 plus runtime-loaded-`ref_gl` engine, never change
`gl_mode` or `vid_fullscreen` after the renderer's first init on the G3.**

## Cfgs ship comment-stripped

`deploy.sh` and `make-dmg.sh` pipe each cfg through
`sed -e 's,//.*,,' -e 's/[[:space:]]*$//'` and drop blank lines when copying into
the bundle. The repo files keep all their documentation; the shipped files are
bare `set` lines.

Root cause (v2.2.0, fixed v2.2.1): the layers are `Cbuf_AddText`'d back to back
into a fixed buffer. Verbose documentation comments pushed each file to
4.7–7.3 KB, and two together exceeded the then-8 KB `cmd_text_buf`
(`cmdparser.c`) on **every** machine, on the G5, 4696 + 6772 = **11,468 bytes**
→ `Cbuf_AddText: overflow`. The engine drops the overflowing text and the parser
desyncs: leftover comment words execute as commands (`Unknown command "the"`,
`Line has unmatched quote, discarded`) and the overlay lands only partially. The
resulting inconsistent renderer state survived a timedemo but **wedged the R300
driver on a real map load**. As belt and braces `cmd_text_buf` and
`defer_text_buf` were raised **8 KB → 64 KB** (now `65536` in tree).

**Shipped config text has a hard size budget. Do not trust "it's just a
comment".**

## The machine map, and where it deliberately differs from the sister ports

The map covers more models than the fleet contains, because an unmapped model is
not always harmless.

| `hw.model` | Cfg |
|---|---|
| `PowerMac1,1` | `autoexec-yosemite` (G3 750, Rage 128, Panther) |
| `PowerMac3,1` | `autoexec-sawtooth` (G4 7400, GeForce2 MX) |
| `PowerMac3,5` | `autoexec-quicksilver` (G4 7450, Radeon 9000 Pro) |
| `PowerMac10,1` | `autoexec-mini-g4` (G4 7447A, Radeon 9200) |
| `PowerMac8,1` / `PowerMac8,2` / `PowerMac12,1` | `autoexec-imac-g5` |
| `PowerMac4,2` / `PowerMac6,1` / `PowerMac6,3` | `autoexec-imac-g4` |
| `Macmini2,1` | `autoexec-mini-intel` (Core 2 Duo, GMA 950, Lion) |
| `iMac19,1` | `autoexec-imac-2019` (Radeon Pro 580X, Sequoia) |

- **The three iMac G5 entries are a SAFETY entry, not a tuning one.** The
  `ppc970` baseline asks for 1024x768, which on an R300 iMac is a fullscreen
  *mode switch*, the one thing the Leopard Radeon 9600 driver cannot survive
  (ADR 0008). The overlay's `vid_desktopfullscreen` makes it a same-mode
  capture. Only `8,2` is in the fleet; `8,1` and `12,1` are mapped so they
  cannot fall through to the hazardous default.
- **The iMac G4 entries are untested**, there is no iMac G4 here. The profile
  takes the sawtooth visual stack, the validated floor for the weakest member of
  that family (700 MHz + GeForce2 MX); faster ones leave framerate on the table,
  which is the right way round for a profile nobody has run.
- **Deliberate divergence from QuakeSpasm:** that port's `imac-g4` overlay takes
  the panel's native resolution. This one pins 1024x768. The 17"/20" sunflower
  panels are 1440x900 / 1680x1050, and a GeForce4 MX filling those with this
  visual stack would fall well short of the G4 floor, whereas 1024x768 is what
  every other G4 overlay here is tuned and benched at. The mode switch that
  implies is safe on these GPUs; the hang hazard is specific to the R300, and no
  iMac G4 shipped one.

## Alternatives rejected

**`baseq2/autoexec.cfg` via the gamedir filesystem.** Mixed engine-shipped
config with user game data, so "drop the `.app` plus your paks" was not actually
enough, and the `.app` stopped being a self-contained distribution unit.
CFBundle resolves `Resources/` relative to the executable's own image path.

**Per-machine only, with no per-arch baseline.** That was the design until
2026-05-31, and it meant any Mac whose `hw.model` was not in the map got stock
yquake2 defaults.

**A first-launch `vid_restart` to apply the overlay early.** Tried in v2.2.2,
reverted. See ADR 0010.

## Consequences

- Every per-machine visual decision is a cfg edit plus a redeploy, no rebuild.
- Adding a machine is: a `deploy.sh` case, a new
  `scripts/bundle/autoexec-<machine>.cfg` started from the closest GPU class,
  and an entry in the `misc.c` map.
- Anything set in a layer sticks across launches, so there is no need to seed
  `config.cfg` as well.
