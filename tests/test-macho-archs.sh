#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/macho-archs.sh
. "$repo_root/scripts/macho-archs.sh"

# Capture-format fixtures from otool -h on the shipped six-slice engine.
# Exercise the parser on Linux as well as the orchestration Mac.
otool() { printf '%s\n' "$fixture"; return "${tool_status:-0}"; }
fixture='engine (architecture ppc750):
Mach header
magic cputype cpusubtype caps filetype ncmds sizeofcmds flags
0xfeedface 18 9 0x00 2 17 2724 0x00000085
0xfeedface 18 10 0x00 2 17 2724 0x00000085
0xfeedface 18 100 0x00 2 17 2724 0x00000085
0xfeedfacf 16777223 3 0x80 2 22 3456 0x00000085
0xfeedface 7 3 0x00 2 23 3140 0x00000085
0xfeedfacf 16777228 0 0x00 2 28 3776 0x00200085'
[ "$(macho_archs ignored)" = 'ppc750 ppc7400 ppc970 x86_64 i386 arm64' ]
fixture='0xfeedface 18 0 0x00 6 17 2804 0x00100085'
[ "$(macho_archs ignored)" = ppc ]
for fixture in '' 'not a Mach-O' '0xfeedface 18 99' '0xfeedfacf 18 10' \
  $'0xfeedface 18 9\n0xfeedface 18 99'; do
  if macho_archs ignored >/dev/null; then
    echo "accepted invalid header: $fixture" >&2
    exit 1
  fi
done
fixture='0xfeedface 18 9'
tool_status=1
if macho_archs ignored >/dev/null; then
  echo 'ignored otool failure' >&2
  exit 1
fi
echo 'Mach-O architecture parser: PASS (six slices, generic PPC, malformed and failed reads)'
