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

if [ "$DRY_RUN" = "1" ]; then
  echo "=== DRY RUN — set DRY_RUN=0 to actually delete ==="
  RM="echo would-rm"
else
  echo "=== LIVE RUN — deleting for real ==="
  RM="rm -rf"
fi

# Paths to remove. Quoted carefully because the parent path contains a space.
#
# Tier 1 — legacy 1999 Classic Mac OS binaries + plugins (won't run on Tiger):
LEGACY_BINARIES=(
  "Quake 2™"
  "Q2DedicatedServer"
  "Read Me.app"
  "ref_gl.lib"
  "ref_soft.lib"
)

# Tier 2 — HFS+ system / Finder cruft:
SYSTEM_CRUFT=(
  ".DS_Store"
  ".Spotlight-V100"
  ".fseventsd"
  ".HFS+ Private Directory Data"
  $'\x00\x00\x00\x00HFS+ Private Data'   # the null-prefix HFS metadata dir
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
