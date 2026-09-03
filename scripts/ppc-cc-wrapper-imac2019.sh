#!/bin/sh
# ppc-cc-wrapper-imac2019.sh — CC shim for building the PPC client on
# imac-2019 (issue #40).
#
# imac-2019's GCC14 PPC cross-toolchain has no Objective-C frontend
# (~/gcc14-ppc). SDLMain.m — the one .m file in the whole tree, and the
# thing that makes the client (not just ref_gl.so/q2ded/game.so) an
# Objective-C build — needs a SEPARATE toolchain, ~/gcc14-ppc-objc, built
# --enable-languages=c,objc specifically for this (see
# old-mac-build-host/docs/imac-2019.md, "A second PPC cross-compiler with
# Objective-C"). This script is what build.sh points CC at for imac-2019:
# everything routes to the plain compiler unchanged, except SDLMain.m,
# which gets the ObjC-capable one with the flags that file actually needs.
#
# Recipe verified compile+link clean against real Foundation/AppKit on
# g3/g4/g5 (build-host, 2026-08-28/29 — see docs/imac-2019.md). This
# script is the build.sh-integration half of that finding — the part the
# doc explicitly flagged as still-undone per-port work.
#
# All three PPC slices share the SAME SDK now (10.3.9 — issue #42 moved
# g5 off its old 10.5-only pin), so this can be hardcoded rather than
# threaded through from build.sh per target.

REGULAR_CC="/Users/mini/gcc14-ppc/bin/powerpc-apple-darwin8-gcc"
OBJC_CC="/Users/mini/gcc14-ppc-objc/bin/powerpc-apple-darwin8-gcc"
OBJC_GCCBASE="/Users/mini/gcc14-ppc-objc/lib/gcc/powerpc-apple-darwin8/14.2.0"
SDK="/Users/mini/SDKs/MacOSX10.3.9.sdk"
PTRDIFF_HDR="/Users/mini/ptrdiff-compat-full.h"

case " $* " in
  *filesystem.c*)
    # Same GCC14 -mcpu=970 -O2/-O3 register-allocation bug class as
    # SDLMain.m below, different symptom: FS_InitFilesystem's inlined
    # copy of FS_CreatePath(fs_gamedir) calls strchr with r3 == 0x1 --
    # i.e. `old` (a copy of fs_gamedir's own address, loaded correctly
    # earlier in the same function via the normal non-lazy-pointer
    # indirection every other extern global uses here too, confirmed
    # identical between -mcpu=970 and -mcpu=7400 -S output) reads back
    # as 0 by the time the inlined loop runs. EXC_BAD_ACCESS /
    # KERN_PROTECTION_FAILURE at 0x1, real g5-tiger hardware, issue #53.
    # Not the addressing mechanism itself (proven identical both ways);
    # a register clobbered across the long FS_InitFilesystem body that
    # -mcpu=970's scheduler reuses where -mcpu=7400's does not -- same
    # shape as SDLMain.m's r27 bug, not re-derived instruction-for-
    # instruction since the fix is identical either way: -O0 makes it
    # go away (confirmed: real g5-tiger launch, full demo playback, no
    # crash). filesystem.c also has genuinely hot functions
    # (FS_LoadFile et al.), unlike SDLMain.m's true run-once init, but
    # they are disk/zip-bound, not render-bound, and this port is never
    # benched mid-level-load -- -O0 for the whole file is the same
    # low-risk trade already made for SDLMain.m, not a new kind of risk.
    exec "$REGULAR_CC" "$@" -O0
    ;;
  *SDLMain.m*)
    # -fnext-runtime: NOT the default for this GCC — without it, it emits
    # the GNU Objective-C runtime ABI, which is incompatible with Apple's
    # real Cocoa/Foundation frameworks (confirmed: installs libobjc-gnu,
    # not libobjc). -nostdinc + explicit -isystem: same include-fixed
    # Panther-bootstrap shadow g4/g5 already route around for C files
    # (build.sh's GCC_ALTIVEC_INC), needed here too and for g3 as well
    # since ObjC compilation wasn't part of that C-only finding.
    # -nostdinc also drops the SDK's implicit framework search, so
    # -iframework has to come back explicitly or <Cocoa/Cocoa.h> fails.
    # -O0 override at the end, not the flags this script forwards from
    # build.sh's own OSX_ARCH ("$@" carries a -O3 for every PPC target) --
    # gcc takes the LAST -O flag on the command line, so this wins.
    #
    # Load-bearing, not a style choice: GCC14 has a real register-
    # allocation bug at -mcpu=970 -O2/-O3 in exactly this file. It reuses
    # r27 as a zeroed literal (`li r27,0`) at the SAME point the working
    # (-mcpu=7400) build still needs r27 holding a live selector-table
    # base address across the setActivationPolicy: respondsToSelector:
    # branch, producing `lwz rX,1000(r27)` -- a null-plus-offset
    # dereference. SIGBUS in main(), before any output, on real g5
    # hardware. Confirmed by diffing -S assembly for -mcpu=7400 vs
    # -mcpu=970 side by side, same source, same everything else; still
    # present at -O2, gone at -O0 (which doesn't do the kind of
    # cross-branch register-lifetime optimization that causes it -- not
    # just "didn't happen to trigger this time"). This file runs once at
    # process startup, so -O0 here costs nothing measurable. Issue #40.
    exec "$OBJC_CC" -fnext-runtime -nostdinc \
      -isystem "$OBJC_GCCBASE/include" \
      -isystem "$OBJC_GCCBASE/../../../../powerpc-apple-darwin8/include" \
      -isystem "$SDK/usr/include" \
      -iframework "$SDK/System/Library/Frameworks" \
      -include "$PTRDIFF_HDR" \
      "$@" -O0
    ;;
  *)
    exec "$REGULAR_CC" "$@"
    ;;
esac
