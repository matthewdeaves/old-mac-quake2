#!/usr/bin/env bash
# Tidy up quicksilver:~/Desktop/Quake 2/ — remove legacy 1999/2006 Mac cruft,
# keep the game data we actually need. Mirrors what we did for QuakeSpasm.
#
# usage: scripts/tidy-quicksilver.sh             # DRY RUN (default) — prints what would be deleted
#        DRY_RUN=0 scripts/tidy-quicksilver.sh   # actually delete
#
# This is a one-shot cleanup, not part of the regular build/deploy loop.
# Run once, after the user has confirmed the cleanup plan, then forget it
# exists.
#
# Operates IN PLACE on the existing folder name "Quake 2" (with space).
# We do NOT rename to "quake2" — that's a separate decision, and rsync
# paths in deploy.sh will handle whatever name we settle on.

set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
HOST="${HOST:-quicksilver}"
Q2DIR="${Q2DIR:-/Users/mini/Desktop/Quake 2}"

# Claim the machine for the whole run. Same re-exec pattern as bench.sh:103-107,
# and for the same reason: bash traps REPLACE rather than compose, so a release
# trap installed here would be silently discarded by any trap set later and the
# box would stay claimed until the stale reclaim. `--run` makes the lock a
# property of the invocation, so it is released however this exits.
#
# This script sshes to a named machine and runs `rm -rf` on it. It did that
# without claiming anything, so it could delete files under a session that held
# the lock and was mid-deploy or mid-bench. Of the three gaps in issue #18 this
# is the one with no recovery.
#
# The DRY_RUN default does not make the claim optional. A dry run still sshes to
# the box, and the point of the lock is that nobody else has to reason about
# what our connection is doing there.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ -z "${RETRO_BENCH_LOCK:-}" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "tidy" -- "$0" "$@"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "=== DRY RUN — set DRY_RUN=0 to actually delete ==="
  RM="echo would-rm"
else
  echo "=== LIVE RUN — deleting for real ==="
  RM="rm -rf"
fi

# Paths to remove. Quoted carefully because the parent path contains a space.
#
# Tier 1 — legacy 1999 Classic Mac OS binaries + plugins (won't run on Tiger).
# NOT included: Q2DedicatedServer — keep it. It's a 2006 PPC Mac OS X build
# that does run on Tiger, and the user wants to keep the option to host
# multiplayer from the G4.
LEGACY_BINARIES=(
  "Quake 2™"
  "Read Me.app"
  "ref_gl.lib"
  "ref_soft.lib"
)

# Tier 2 — Finder cruft only. We deliberately do NOT touch
# ".HFS+ Private Directory Data" or the null-prefix HFS+ metadata dir —
# those are filesystem-internal artifacts the OS manages, invisible in
# Finder, and deleting them can break the volume's journaling/hardlinks.
# Leave them alone.
SYSTEM_CRUFT=(
  ".DS_Store"
  ".Spotlight-V100"
  ".fseventsd"
  "TheVolumeSettingsFolder"
)

# Tier 3 — legacy documentation (we'll move these to docs/ rather than nuke).
# Treat as a separate step; user can choose to keep or toss.
LEGACY_DOCS=(
  "Commercial Exploitation"
  "QII License Information"
  "Quake II License"
  "Readme(pt1)"
  "Readme(pt2)"
  "Readme(pt3)"
  "Release Notes"
  "rel notes (word)"
)

# Tier 4 — mission pack stubs that contain only Classic-Mac plugin folders
# (GameMac.q2plug) with no pak data. Remove the dirs entirely; the user
# can drop in real mission packs later if they source the paks.
EMPTY_MISSION_PACKS=(
  "rogue"
  "xatrix"
  "action"
)

# Tier 5 — Classic-Mac-era plugin cruft inside baseq2/ and ctf/ (the dirs
# with real pak data). Keep the dir, remove just the legacy plugin bits.
BASEQ2_CRUFT=(
  "baseq2/GameMac.q2plug"
  "baseq2/gameppc.lib"
  "baseq2/Icon"
)
CTF_CRUFT=(
  "ctf/GameMac.q2plug"
  "ctf/gameppc.lib"
)

ssh_rm() {
  local path="$1"
  if [ "$DRY_RUN" = "1" ]; then
    ssh "$HOST" "[ -e \"$Q2DIR/$path\" ] && echo would-rm: \"$Q2DIR/$path\" || true"
  else
    ssh "$HOST" "rm -rf \"$Q2DIR/$path\""
    echo "rm'd: $path"
  fi
}

echo
echo "--- Tier 1: legacy 1999/2006 binaries + Classic-era plugins ---"
for f in "${LEGACY_BINARIES[@]}"; do ssh_rm "$f"; done

echo
echo "--- Tier 2: HFS+/Finder metadata cruft ---"
for f in "${SYSTEM_CRUFT[@]}"; do ssh_rm "$f"; done

echo
echo "--- Tier 3: legacy docs (consider keeping in ~/quake2/docs/ instead) ---"
echo "    (skipping by default — copy to local docs/ before deciding)"
# for f in "${LEGACY_DOCS[@]}"; do ssh_rm "$f"; done

echo
echo "--- Tier 4: empty mission pack stubs (no pak data, only Classic plugin folders) ---"
for f in "${EMPTY_MISSION_PACKS[@]}"; do ssh_rm "$f"; done

echo
echo "--- Tier 5: legacy plugin cruft inside baseq2/ and ctf/ ---"
for f in "${BASEQ2_CRUFT[@]}"; do ssh_rm "$f"; done
for f in "${CTF_CRUFT[@]}"; do ssh_rm "$f"; done

echo
echo "=== KEEPING (sanity check) ==="
ssh "$HOST" "ls -la \"$Q2DIR/baseq2/\" 2>/dev/null | grep -E 'pak[0-9]|players|video|save|config|maps' | awk '{print \$NF}'" || true
echo "  + ctf/pak0.pak ctf/pak1.pak ctf/players ctf/save ctf/readme.txt"
echo "  + Quake II.app (existing build — replace once we ship our own)"

echo
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN complete. Re-run with DRY_RUN=0 to actually delete."
fi
