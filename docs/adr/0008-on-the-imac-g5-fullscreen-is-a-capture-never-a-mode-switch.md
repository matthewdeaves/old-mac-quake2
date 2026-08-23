# 8. On the iMac G5: fullscreen is a same-mode capture, never a mode switch

Date: 2026-08-20 (records a decision taken 2026-05-31)
Status: accepted

## HAZARD

**The ATI Radeon 9600 (R300 / RV351) Leopard driver hard-hangs the entire OS on
a fullscreen video-mode SWITCH to a non-native size.** Not a crash: a full
GPU/kernel lockup. Grey screen, no ping, no SSH, fans ramp to maximum (the G5
SMU's thermal failsafe when the kernel stops servicing it). **Recoverable only
by the physical power button.** Machine: `PowerMac8,2`, 2.0 GHz PPC 970FX,
Radeon 9600 128 MB, Mac OS X 10.5.8, native panel 1440x900 (the 20" model is
1680x1050).

Benching the G5 headless with unguarded scripts would brick it with no remote
recovery. **Never bypass the mitigations below, and never trigger a remote
non-native fullscreen mode switch on the G5.**

There are two wedge severities, and they are worth telling apart:

- **Fullscreen mode switch:** full OS death, physical power cycle only.
- **Windowed distress:** half-alive; SSH still answers, recover with
  `ssh imac-g5 'sudo /sbin/reboot'`. Safe-ish to iterate.

**Rule while iterating headless: stay windowed, or native same-mode fullscreen
only.**

## Decision

**Request fullscreen at the exact current desktop resolution and depth, so SDL
does a same-mode display CAPTURE with no resolution change.** As a bonus this
auto-picks each panel's native max resolution with no per-model hard-coding.

SDL 1.2 has no built-in desktop fullscreen, so it was added:

- **`vid_desktopfullscreen` cvar** (`r_main.c` + `backends/sdl/refresh.c`):
  captures the desktop resolution at SDL video init and substitutes it for the
  requested size when fullscreen. Default off, zero effect on every other
  machine. ON in the `ppc970` baseline and the `imac-g5` overlay.
- **`GLimp_ForceDesktopFullscreen()`** (`refresh.c`): detects the iMac G5 family
  by `hw.model` **pre-GL**, so it protects the very first `VID_Init`, and forces
  same-mode capture for **every** fullscreen request independent of cvar or
  config. Proven with a pathological-config audit: `vid_fullscreen 1` +
  `vid_desktopfullscreen 0` + a non-native 1024x768 planted in `config.cfg`,
  launched with the overlay disabled, the engine logged the requested 1024x768
  but captured native 1440x900 and the OS did not hang.
- **`bench.sh`** refuses fullscreen at any non-native resolution on `imac-g5`
  (`exit 3`), defaults to native-resolution capture, and offers `G5_WINDOWED=1`
  for safe windowed iteration. Both vid cvars are set explicitly on the command
  line so a leftover archived value cannot change the measured mode.
- **`screenshot.sh`** does the same, and defaults every target to the safe
  capture path — only machines with a confirmed non-R300 GPU opt into the
  mode-switch. `GLimp_ForceDesktopFullscreen()` also covers `PowerMac7,3`
  (the g5-desktop/g5-panther/g5-tiger tower, measured ATY,RV351, same R300
  family). Issue #31. **`parallel-bench.sh`** benches the G5 leg at native
  1440x900 rather than the shared 1024x768 / 640x480 sweep, which it would
  refuse.
- The `misc.c` machine map routes all three iMac G5 model IDs to the overlay as
  a safety entry (ADR 0007).

## Killing a fullscreen G5 run: TERM first: always

`killall -KILL` alone on a fullscreen G5 session skips SDL's shutdown, so the
R300/Leopard captured framebuffer is never released and the screen goes **black**
(the OS is fine and ssh is alive). Recovery: relaunch and exit cleanly with
`-TERM`. **Always `killall -TERM`, sleep, then `-KILL` as a backstop.**
`bench.sh` already does this; the harm came from an ad-hoc KILL. The Rage 128 G3
tolerates a hard KILL; the R300 G5 does not.

## What does NOT apply here

The sister QuakeSpasm port's R300 bug had two halves: the fullscreen mode-switch
hang, and a GLSL/VBO/NPOT/`glGenerateMipmap` hang. **Only the mode-switch half
applies to this port.** Verified: there is no VBO, FBO, GLSL, NPOT or
auto-mipmap use anywhere in `yquake2/src/refresh/`. The R300 is the only GPU in
the fleet advertising OpenGL 2.0 (`GL_RENDERER: ATI Radeon 9600 OpenGL Engine`,
`GL_VERSION: 2.0 ATI-1.5.48`), which is why it is the only one that ever ran
that path in QuakeSpasm.

Two claims from those inherited notes are **rejected for this repo**, because
they describe upstream yquake2 rather than the pinned 5.11 tree (ADR 0002):

- REJECTED: "set `vid_renderer gl1` on the G5." There is one renderer here and
  no such cvar.
- REJECTED: "use `vid_fullscreen 2` (SDL2 `FULLSCREEN_DESKTOP`)." This tree is
  SDL 1.2; the equivalent is `vid_desktopfullscreen`, which is the cvar this
  port added.

The silicon is genuinely GL2-capable; the **driver** is broken and there is no
newer Leopard ATI driver to switch to.

## Measured cost of the resulting configuration

Benched 2026-05-31 on `imac-g5`:

- The demo is **CPU-bound on the 970FX**: ~116 fps demo1 / ~114 fps demo2, flat
  across 640x480, 1024x768 and native 1440x900.
- **Stencil shadows are free** here: 116.1 vs 115.9. The R9200/Tiger cliff
  (ADR 0010) is absent on the 9600/Leopard driver, so they are enabled.
- **MSAA is fillrate-bound at native resolution:** 0x = 116, 2x = 52.5,
  4x = 27 fps. Shipped **2x**, per the visuals-over-framerate preference.
- Production render, native 1440x900, full tune + stencil + 2x MSAA:
  **46.8 fps demo1 / 45.8 fps demo2**.

(Earlier figures of 52.6 / 51.7 were taken while the `Cbuf` overflow was
silently dropping the `imac-g5` overlay, so they missed stencil, glows and
caustics. 46.8 / 45.8 are the corrected numbers. See ADR 0007.)

## Consequences

- The G5 runs at native resolution only, and that is a deliberate
  visuals-over-framerate trade, not a limitation of the tune.
- Three separate guards exist for one hazard (cvar, engine `hw.model` force,
  script refusal), on purpose: the engine one is the only one that survives a
  hand-edited `config.cfg`.
