#!/usr/bin/env bash
# Source on the orchestration Mac. Modern lipo omits PowerPC; numeric Mach
# headers remain readable by otool. Reject unknown members, not just missing ones.
macho_archs() {
  otool -h "$1" | awk '
    $1 == "0xfeedface" || $1 == "0xfeedfacf" {
      arch = ""
      if ($2 == 18 && $1 == "0xfeedface") {
        if ($3 == 0) arch = "ppc"
        if ($3 == 9) arch = "ppc750"
        if ($3 == 10) arch = "ppc7400"
        if ($3 == 100) arch = "ppc970"
      }
      if ($2 == 7 && $1 == "0xfeedface" && $3 == 3) arch = "i386"
      if ($2 == 16777223 && $1 == "0xfeedfacf" && $3 == 3) arch = "x86_64"
      if ($2 == 16777228 && $1 == "0xfeedfacf" && $3 == 0) arch = "arm64"
      if (arch == "") bad = 1
      else { printf "%s%s", sep, arch; sep = " "; count++ }
    }
    END { print ""; if (!count || bad) exit 1 }
  '
}
