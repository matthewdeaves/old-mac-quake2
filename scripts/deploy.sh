#!/usr/bin/env bash
# Deploy a yquake2 build to a target machine and stage game data.
# Flat layout (no .app bundle yet — Phase A.2 will add that):
#
#   ~/Desktop/quake2/
#     quake2              the engine binary
#     q2ded               dedicated server
#     ref_gl.so           OpenGL renderer (dlopen'd)
#     SDL.framework/      fat SDL 1.2 — sits beside the binary so the
#                         framework's @executable_path install_name
#                         resolves correctly
#     baseq2/
#       game.so           Q2 game logic plugin
#       pak0.pak          symlinked to local game-data if the host
#       pak1.pak          already has paks at a known location;
#       pak2.pak          otherwise rsync'd from workstation
#
# Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019>
#
# Machine identity → binary mapping (same scheme as the QuakeSpasm sister
# project's deploy.sh: machine names use Apple codenames; binary names use
# chip family):
#   yosemite    → q2-g3      (PPC 750, 10.3.9 SDK)
#   sawtooth    → q2-g4      (PPC 7400 baseline, 10.4u SDK)
#   quicksilver → q2-g4      (PPC 7450 — same binary)
#   mini-g4     → q2-g4      (PPC 7447A — same binary)
#   mini-intel  → q2-lion    (x86_64, native Lion build)
#   imac-2019   → q2-lion    (x86_64; same binary, faster machine)

set -euo pipefail

TARGET="${1:?usage: $0 <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$TARGET" in
  yosemite)
    # PowerMac1,1 — only G3 / Panther target. Panther ships rsync 2.5.x
    # which doesn't speak modern wire protocol; --protocol=29 is the
    # max it'll accept from a newer client. (QuakeSpasm hit the same.)
    HOST=yosemite; BIN_TARGET=g3
    RSYNC_EXTRA="--protocol=29"
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'   # we'll create this if missing
    ;;
  sawtooth)
    HOST=sawtooth; BIN_TARGET=g4
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  quicksilver)
    HOST=quicksilver; BIN_TARGET=g4
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  mini-g4)
    HOST=mini-g4; BIN_TARGET=g4
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  mini-intel)
    HOST=mini-intel; BIN_TARGET=lion
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  imac-2019)
    HOST=imac-2019; BIN_TARGET=lion
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BUILD_DIR="$REPO_ROOT/build/q2-$BIN_TARGET"
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "deploy.sh: build/q2-$BIN_TARGET not found — run scripts/build.sh $BIN_TARGET first" >&2
  exit 1
fi

# Stage layout locally, then rsync. Using a temp dir means we can ship
# symlinks to SDL.framework slices cleanly without rsync flattening
# them on the way out.
STAGE=$(mktemp -d -t q2-deploy.XXXXXX)
trap "rm -rf '$STAGE'" EXIT

echo "[deploy] stage flat bundle"
mkdir -p "$STAGE/baseq2"
cp "$BUILD_DIR/quake2" "$BUILD_DIR/q2ded" "$BUILD_DIR/ref_gl.so" "$STAGE/"
cp "$BUILD_DIR/baseq2/game.so" "$STAGE/baseq2/"
chmod +x "$STAGE/quake2" "$STAGE/q2ded"
cp -a "$REPO_ROOT/MacOSX/SDL.framework" "$STAGE/"

echo "[deploy] ship to $HOST:~/Desktop/quake2/"
# --checksum to defeat the size+mtime heuristic that left a stale icon
# on the QuakeSpasm sister project. On a 3 MB payload (binary + SDL
# framework slice) the extra hashing cost is negligible.
rsync -av --partial --checksum $RSYNC_EXTRA \
  -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/" "$HOST:Desktop/quake2/" | tail -8

# Game-data step. Three paths:
#   1. host already has the paks at GAME_DATA_DIR — symlink so we don't
#      duplicate 200 MB of paks per deploy.
#   2. host doesn't have paks but workstation has them at .game-data/ —
#      rsync them once into ~/Desktop/quake2/baseq2/ on the host.
#   3. neither — error out with a hint.
echo "[deploy] resolve game data on $HOST"
REMOTE_HAS_PAKS=$(ssh "$HOST" "[ -f '$GAME_DATA_DIR/pak0.pak' ] && echo yes || echo no")
if [ "$REMOTE_HAS_PAKS" = "yes" ]; then
  ssh "$HOST" "cd ~/Desktop/quake2/baseq2 &&
    for p in pak0 pak1 pak2; do
      ln -sfn \"\$HOME/$GAME_DATA_DIR/\$p.pak\" \"\$p.pak\"
    done
    ls -la | grep pak"
elif [ -f "$REPO_ROOT/.game-data/baseq2/pak0.pak" ]; then
  echo "[deploy] $HOST has no paks at ~/$GAME_DATA_DIR — pushing from .game-data/"
  rsync -av --partial $RSYNC_EXTRA \
    -e 'ssh -o ServerAliveInterval=15' \
    "$REPO_ROOT/.game-data/baseq2/pak0.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak1.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak2.pak" \
    "$HOST:Desktop/quake2/baseq2/" | tail -5
else
  echo "deploy.sh: no game data on $HOST and none in .game-data/ — populate one" >&2
  echo "  hint: rsync -av 'quicksilver:Desktop/Quake 2/baseq2/pak*.pak' .game-data/baseq2/" >&2
  exit 1
fi

echo "[deploy] OK"
ssh "$HOST" 'ls -la ~/Desktop/quake2/ | head -10'
