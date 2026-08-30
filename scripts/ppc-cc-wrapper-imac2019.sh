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
    exec "$OBJC_CC" -fnext-runtime -nostdinc \
      -isystem "$OBJC_GCCBASE/include" \
      -isystem "$OBJC_GCCBASE/../../../../powerpc-apple-darwin8/include" \
      -isystem "$SDK/usr/include" \
      -iframework "$SDK/System/Library/Frameworks" \
      -include "$PTRDIFF_HDR" \
      "$@"
    ;;
  *)
    exec "$REGULAR_CC" "$@"
    ;;
esac
