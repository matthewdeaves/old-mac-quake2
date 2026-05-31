# Getting a Quake engine working on the iMac G5 (Leopard 10.5.8, ATI Radeon 9600)

Notes from the **QuakeSpasm** PPC port for the **Quake II / yquake2** sister
project. Hardware: iMac G5 `PowerMac8,2`, 2.0 GHz PPC 970, **ATI Radeon 9600
(R300 family / RV351), 128 MB**, Mac OS X **10.5.8 Leopard**, native panel
**1440x900** (17" model; the 20" model is 1680x1050).

This was the first **Leopard** machine and the first **OpenGL-2.0-class GPU**
in the fleet, and it exposed two distinct problems. The Q2 engine differs, but
the **root causes and the operational gotchas transfer directly**. Verify the
specifics against the yquake2 source — the principles are what matter.

---

## TL;DR — what actually fixed it

1. **The killer bug: the ATI R300 driver HARD-HANGS on the GL2 / GLSL / VBO
   path under Leopard.** Not a crash — a full GPU lockup that takes the whole
   OS down (no SSH, fans ramp to max). **Force the renderer onto the GL 1.x
   fixed-function path** and it's rock-solid and fast.
2. **SDL had to be rebuilt for Leopard**, but that was *not* the hang. (It was
   a necessary correctness fix; see below.)
3. **Fullscreen must avoid a video-mode SWITCH.** Use a **same-mode display
   CAPTURE at the native desktop resolution** instead. This also auto-selects
   each panel's native max res (1440x900 / 1680x1050) with no hard-coding.

Result on QuakeSpasm: stable **119 fps at native 1440x900 fullscreen, 32-bit
color (24-bit depth + stencil)** with the full visual stack.

---

## Problem 1 — the GPU hard-hang (the important one)

### Symptom
- Fullscreen launch: instant **full-OS lockup** — grey screen, no ping, no
  SSH, fans to maximum (the G5 SMU's thermal failsafe when the kernel stops
  servicing it). Unrecoverable remotely; needs a physical power-cycle.
- Windowed launch: rendered a few frames, then the **timedemo crawled** (60s+
  and never finished, vs ~3s healthy) and the GPU wedged — but this time
  *half-alive* (SSH still answered; recoverable via `sudo /sbin/reboot`).
- No panic.log, no crash report → it's a **driver/GPU lockup**, not a software
  crash.

### Root cause
The Radeon 9600 (R300) is the **only GPU in the fleet that advertises OpenGL
2.0**, so it's the only one that ever ran the engine's **GLSL + VBO** path.
The R300's **Mac GL2 driver on Leopard is broken** — exercising GLSL (and/or
VBO / NPOT textures / `glGenerateMipmap`) locks the GPU. Every other machine
(GeForce2 MX, Radeon 9000/9200, Rage128) is OpenGL 1.2–1.3 and silently falls
back to fixed-function, so they never hit it.

Corroboration: QuakeSpasm **bug #43** documents the exact card+OS, and the
regression window ("0.85.x worked, 0.91.0 broke") is precisely when GLSL+VBO
were added. **NVIDIA G5s (GeForce 5200/6800) drive GLSL fine** — so gate on the
*renderer string*, not the CPU/slice.

### Fix (QuakeSpasm)
In `GL_CheckExtensions`, detect the renderer string and force the GL 1.x path
— mirroring an existing "skip CVA on Rage 128" idiom:

```c
qboolean gl_ati_r300_force_gl1 = gl_renderer &&
    (strstr(gl_renderer,"Radeon 9500") || strstr(gl_renderer,"Radeon 9600") ||
     strstr(gl_renderer,"Radeon 9700") || strstr(gl_renderer,"Radeon 9800")) &&
    !COM_CheckParm("-atigl");        // -atigl = opt-in override for A/B
```
…then skip VBO, NPOT, GLSL and warp-mipmap generation when that's set. The
engine already had `-noglsl -novbo -notexturenpot -nowarpmipmaps` cmdline
switches — validating the fix needed **no rebuild**, just those flags. Renderer
string seen: `GL_RENDERER: ATI Radeon 9600 OpenGL Engine`, `GL_VERSION: 2.0
ATI-1.5.48`.

### How this maps to yquake2 / Quake II
- yquake2 ships **two renderers**: `ref_gl1` (OpenGL 1.4 fixed-function) and
  `ref_gl3` (OpenGL 3.2 core). The R300 only does **GL 2.0/2.1**, so **`ref_gl3`
  cannot initialize at all** — Q2 on the G5 **must use `ref_gl1`** (set
  `vid_renderer "gl1"` / `gl_renderer "gl1"`; verify the cvar name in-repo).
  That is the GL-1.x-equivalent and the direct analogue of this fix.
- **Don't stop there:** even `ref_gl1` may touch GL2-era extensions
  (multitexture is fine; watch anything VBO / shader / FBO / NPOT /
  auto-mipmap). If Q2 wedges the GPU on the G5, the suspect is whatever
  GL2-ish path `ref_gl1` still uses — gate it off on the R300 renderer string,
  same pattern.
- **Is the GPU genuinely GL2.0-capable? Yes — but the driver is broken, not the
  silicon.** There's no newer Leopard ATI driver to switch to. So GL 1.x isn't
  a compromise; it's the correct target. We lose *no meaningful visuals or fps*
  — fixed-function ran 119 fps native with shadows, emissive lights, water
  alpha, 16x aniso, trilinear, etc. On R300 the GLSL vertex path is partly
  software-emulated anyway, so GL2 would likely be *slower*, not faster.

---

## Problem 2 — SDL had to be rebuilt for Leopard (necessary, but not the hang)

QuakeSpasm uses **SDL 1.2**. Our fat `SDL.framework`'s PPC slice was built
against the **10.3.9 (Panther) SDK** so it runs on the oldest box (G3/Panther).
That Panther-era build *runs* on Leopard but its fullscreen path is suspect
there. We built a **dedicated SDL 1.2.15 slice against the 10.5 SDK
(`-mcpu=970`, cpusubtype `ppc970`)** and lipo'd it into the framework as a
**separate `ppc970` slice** alongside the generic-`ppc` Panther slice. dyld
auto-selects the `ppc970` slice on the G5; G3/G4 keep the Panther slice → **zero
regression** to other machines.

Gotcha: SDL's build injects `-force_cpusubtype_ALL`, which stamps the dylib as
generic `ppc` and collides with the existing slice. Strip it from the generated
`Makefile` so `-mcpu=970` stamps a real `ppc970` subtype, then
`lipo -create existing.framework new-ppc970.dylib`.

**For yquake2 this maps to SDL2**, which it already uses. The same idea: ensure
the SDL2 you ship is built for **Leopard PPC** (there is a known "SDL2 for
Legacy Mac OS X" port — 2.0.6 for Leopard 10.5+). Build/select a `ppc970`-aware
SDL2. (This was *not* the cause of the hang — that was the GL path — but get it
right for correctness.)

---

## Problem 3 — fullscreen: CAPTURE the native mode, never SWITCH modes

The first full-OS-death wedge was a fullscreen launch that did a **video-mode
SWITCH** (1024x768 on a 1440x900 desktop). The mode *switch* is dangerous on
this driver. The cure that's also the nicest UX:

**Request fullscreen at the EXACT current desktop resolution + depth.** SDL then
does a same-mode **display capture** with no resolution change — which the ATI
driver survives cleanly. Bonus: it **auto-picks each panel's native max res**
(17" = 1440x900, 20" = 1680x1050) with **zero per-model hard-coding**.

- **SDL 1.2 (QuakeSpasm):** there's no built-in "desktop fullscreen", so we
  added one: when `vid_desktopfullscreen` is set, substitute the captured
  desktop `display_width/height/bpp` into `SDL_SetVideoMode` instead of the
  requested size. Gated on a cvar (default off) so only the iMacs use it;
  external-display machines (minis/towers) keep their tuned fixed resolution.
- **SDL2 (yquake2):** you get this **for free** —
  `SDL_WINDOW_FULLSCREEN_DESKTOP`. In yquake2 that's typically **`vid_fullscreen
  2`** (borderless desktop fullscreen) vs `vid_fullscreen 1` (real mode-switch).
  **On the G5, use `vid_fullscreen 2`** — native res, no mode switch, safe.
  Avoid `vid_fullscreen 1` with a non-native resolution.

---

## Operational gotchas on Leopard PPC (will bite the Q2 instance too)

- **Leopard's `sudo` is old (1.6.x) and has NO `-n` flag** (`sudo: illegal
  option -n`). Any `sudo -n ...` reboot helper fails. Use plain `sudo
  /sbin/reboot` (with a NOPASSWD sudoers entry). On QuakeSpasm, `qsreboot.sh`
  needs a Leopard fallback (`sudo -n` → `sudo`).
- **Two wedge severities:**
  - *Fullscreen mode-SWITCH (esp. with GLSL):* **full OS death** — no SSH, only
    a physical power-cycle recovers it. **Never test this remotely if you can't
    reach the power button.**
  - *Windowed / GLSL distress:* **half-alive** — SSH still answers; recover with
    `ssh host 'sudo /sbin/reboot'`. Safe-ish to iterate.
  - **Rule while iterating headless: stay windowed or native-same-mode
    fullscreen only.** Never trigger a non-native fullscreen mode-switch until
    the GL path is proven stable.
- Leopard's `/bin/sh` (in `ssh host '...'`) **lacks `seq`** — use
  `i=0; while [ $i -lt N ]; do …; i=$((i+1)); done`.
- Kill the engine with `killall -KILL quakespasm` after a TERM grace; **don't
  `pkill`** (absent/unreliable on old OS X). Killing mid-fullscreen leaves the
  menu bar geometry briefly offset — purely cosmetic, clears on reboot / display
  change / a clean Quit.
- A timedemo launched via `+timedemo` measures the **initial** video mode; an
  autoexec `vid_restart` to change res lands too late for the measurement. To
  bench at native res, pass the resolution / desktop-fullscreen cvar **on the
  cmdline** so it applies at init (it's read before the first mode-set), not via
  autoexec.

---

## Net result / config defaults that worked (QuakeSpasm G5)
- Engine: GL 1.x forced on the R300 renderer (auto), `-atigl` to override.
- SDL: dedicated `ppc970` Leopard SDL 1.2.15 slice in the fat framework.
- Display: `vid_desktopfullscreen 1` → native-panel-res fullscreen, same-mode
  capture, 32-bit (24-bit depth + stencil shadows) for free.
- Visuals (all GL-1.x fixed-function, proven on the Radeon-9000 G4s): drop
  shadows, emissive fullbright lights, translucent water/lava, 16x anisotropic,
  trilinear, smooth lightstyle interpolation.
- **119 fps** at native 1440x900 fullscreen — huge headroom over the 60 fps
  target.

_— generated by the QuakeSpasm-port Claude session, for the Quake II port._
