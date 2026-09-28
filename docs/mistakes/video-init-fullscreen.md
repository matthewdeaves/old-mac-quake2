# Mistakes: video init and the fullscreen path

Video-init and fullscreen changes that crashed or hung legacy machines, all 2026-05-31. Themes: `vid_restart` is unsafe to issue automatically on the Panther/Rage 128 stack; "green on 4 of 5" is not "works"; a "load-time only / zero risk" change can take a whole machine down on one GPU + OS pair. Standing rules live in ADR 0007 and ADR 0008. Newest first.

## Per-machine config applied AFTER `CL_Init` hard-crashed the G3 on "new game"
The refresh-DLL reload it triggered crashed the Panther/Rage 128 G3 on "start a new game". Root cause and fix: ADR 0007.

## First-launch `vid_restart` for early per-machine defaults (v2.2.2, REVERTED)
Aim: apply tuned fullscreen, resolution and picmip on first launch instead of second. Worked on G4, G5 and Intel; **hard-crashed the G3**: `VID_CheckChanges → VID_LoadRefresh → QGL_Shutdown → Com_Error → VID_Shutdown → R_Shutdown → GLimp_Shutdown → SDL_GL_SwapBuffers`, `EXC_BAD_ACCESS at 0x134`. The same fatal reload, issued deliberately.
A compile guard `#if !(defined(__ppc__) && !defined(__VEC__) && !defined(Q2_ARCH_PPC970))` should have excluded the bare-G3 slice (`gcc-4.0 -arch ppc -mcpu=750` defines only `__ppc__`/`__POWERPC__`, not `__VEC__`), yet the crash persisted identically. Fix: drop `vid_restart`; the real fix moved the config call site (ADR 0007).
Lessons: (a) treat `vid_restart` as interactive-menu-only on legacy Panther/Rage 128; (b) "tested green on 4 of 5" is not "works", the oldest, least forgiving box is where video-init bites; (c) a fix that needs a per-slice compile guard to be safe is wrong for this fleet.

## iMac G5 R300/Leopard driver hard-hangs the OS on a non-native fullscreen switch
Hazard, mitigations and never-bypass rule: ADR 0008. The "load-time only / zero risk" smell test failed: a one-line resolution flag inert everywhere else took a whole machine down on one GPU + OS combination.
Adding a box with a new-to-the-fleet GPU/OS pair: assume the fullscreen path bites first; validate windowed or same-mode before any remote mode switch you cannot physically recover from.

## `killall -KILL` on a fullscreen G5 leaves the screen BLACK
The R300 display capture is never released. Always TERM, sleep, then KILL: ADR 0008.
