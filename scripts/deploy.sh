#!/usr/bin/env bash
# Deploy a yquake2 build to a target machine and stage game data.
#
# Two modes:
#
# Per-target (default, single-arch binary):
#   scripts/deploy.sh <target>
#   Ships a flat layout to ~/Desktop/quake2/:
#     quake2 + q2ded + ref_gl.so + SDL.framework + baseq2/{game.so,paks}
#
# Fat (universal binary, recommended once build-fat.sh has been run):
#   scripts/deploy.sh fat <target>
#   Ships a Quake2.app bundle to ~/Desktop/quake2/Quake2.app/:
#     Contents/MacOS/{quake2,SDL.framework}
#     Contents/Resources/Quake2.icns
#     Contents/Info.plist
#   ref_gl.so + baseq2/ ship to ~/Desktop/quake2/ (outside the bundle)
#   because Q2 resolves ref_gl.so via basedir=. (CWD after the chdir in
#   SDLMain.m, which is the .app's parent dir for Finder launches).
#   The dyld picks ppc750 / ppc7400 / x86_64 per host CPU subtype, so
#   the same Quake2.app runs on G3 Panther, G4 Tiger, and Lion Intel.
#
# Idempotent — safe to re-run.
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
# In fat mode the binary mapping is bypassed — build/q2-fat ships to
# every target.

set -euo pipefail

MODE="per-target"
if [ "${1:-}" = "fat" ]; then
  MODE="fat"
  shift
fi

TARGET="${1:?usage: $0 [fat] <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019>}"
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

# In fat mode, BIN_TARGET is overridden — we ship build/q2-fat to every host.
if [ "$MODE" = "fat" ]; then
  BIN_TARGET="fat"
fi

BUILD_DIR="$REPO_ROOT/build/q2-$BIN_TARGET"
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "deploy.sh: build/q2-$BIN_TARGET not found — run scripts/build.sh $BIN_TARGET first" >&2
  if [ "$MODE" = "fat" ]; then
    echo "  (or scripts/build-fat.sh for the universal binary)" >&2
  fi
  exit 1
fi

# Stage layout locally, then rsync. Using a temp dir means we can ship
# symlinks to SDL.framework slices cleanly without rsync flattening
# them on the way out.
STAGE=$(mktemp -d -t q2-deploy.XXXXXX)
trap "rm -rf '$STAGE'" EXIT

if [ "$MODE" = "fat" ]; then
  echo "[deploy] stage Quake2.app bundle"
  APP="$STAGE/Quake2.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/baseq2"
  cp "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"
  cp "$REPO_ROOT/MacOSX/Quake2.icns"        "$APP/Contents/Resources/"
  cp "$BUILD_DIR/quake2"                    "$APP/Contents/MacOS/"
  cp -a "$REPO_ROOT/MacOSX/SDL.framework"   "$APP/Contents/MacOS/"
  chmod +x "$APP/Contents/MacOS/quake2"
  # ref_gl.so and baseq2/game.so ship OUTSIDE the bundle. Q2 resolves
  # ref_gl.so via basedir=. (the engine's CWD); SDLMain.m chdirs the
  # process to the .app's parent dir on Finder-launch, so basedir=.
  # = ~/Desktop/quake2/ and Q2 finds ref_gl.so there. baseq2/ lives
  # in the same dir for the same reason — Q2's gamedir search walks
  # basedir/baseq2/ for game.so + paks.
  cp "$BUILD_DIR/ref_gl.so"                 "$STAGE/"
  cp "$BUILD_DIR/baseq2/game.so"            "$STAGE/baseq2/"
  cp "$BUILD_DIR/q2ded"                     "$STAGE/" 2>/dev/null || true
  [ -f "$STAGE/q2ded" ] && chmod +x "$STAGE/q2ded"
else
  echo "[deploy] stage flat bundle"
  mkdir -p "$STAGE/baseq2"
  cp "$BUILD_DIR/quake2" "$BUILD_DIR/q2ded" "$BUILD_DIR/ref_gl.so" "$STAGE/"
  cp "$BUILD_DIR/baseq2/game.so" "$STAGE/baseq2/"
  chmod +x "$STAGE/quake2" "$STAGE/q2ded"
  cp -a "$REPO_ROOT/MacOSX/SDL.framework" "$STAGE/"
fi

# Per-machine autoexec. Q2 reads `<basedir>/baseq2/autoexec.cfg` on boot
# (see yquake2/src/common/filesystem.c:FS_ExecAutoexec) and execs it as
# console commands after CL_Init but before late command-line +commands.
# We pick the file by TARGET (machine identity) rather than by binary
# slice — fat-mode means mini-intel and quicksilver share the x86_64 vs
# ppc_7400 slices but have wildly different per-machine tuning (GPU /
# VRAM / OS driver quirks), so the per-machine layer is what we need.
#
# autoexec.cfg WILL override anything set via `+set` on the engine's
# command line (autoexec runs AFTER Cbuf_AddEarlyCommands). bench.sh
# relies on `+set gl_mode -1 +set gl_customwidth/customheight +set
# gl_swapinterval 0` for its per-resolution sweep — so the bundled
# autoexec files deliberately DO NOT set those four cvars. Resolution
# defaults are left to ~/.yq2/baseq2/config.cfg (the per-user persisted
# cvars from the in-game video menu).
AUTOEXEC_SRC="$REPO_ROOT/scripts/bundle/autoexec-$TARGET.cfg"
if [ -f "$AUTOEXEC_SRC" ]; then
  echo "[deploy] stage autoexec for $TARGET"
  cp "$AUTOEXEC_SRC" "$STAGE/baseq2/autoexec.cfg"
else
  echo "[deploy] WARN: no autoexec for $TARGET at $AUTOEXEC_SRC — engine will use defaults" >&2
fi

echo "[deploy] ship to $HOST:~/Desktop/quake2/"
# --checksum to defeat the size+mtime heuristic that left a stale icon
# on the QuakeSpasm sister project. On a few MB payload the extra
# hashing cost is negligible.
# --delete to keep the deploy dir tidy — wipes any stale artifacts from
# a previous mode (e.g. switching from per-target → fat leaves the old
# flat `quake2` + `SDL.framework/` behind otherwise). Excluding baseq2/
# from the delete sweep so existing pak symlinks aren't nuked between
# the rsync and the symlink step below.
rsync -av --partial --checksum --delete --exclude='baseq2/pak*.pak' $RSYNC_EXTRA \
  -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/" "$HOST:Desktop/quake2/" | tail -8

# Game-data step. Make the deploy dir self-contained — the user wants
# ONE Q2 folder on the target with everything needed for the full game,
# not a flat dir that secretly depends on aliases or symlinks back to
# the original game install. So we copy paks rather than symlinking,
# even when the host already has them elsewhere.
#
# Source preference order:
#   1. workstation's .game-data/ (canonical — same paks pushed to every
#      machine, so no per-machine drift)
#   2. host's existing GAME_DATA_DIR (only used as a fallback if the
#      workstation cache doesn't exist yet)
#   3. nothing — error out with a hint
echo "[deploy] resolve game data on $HOST (self-contained copies, not symlinks)"
if [ -f "$REPO_ROOT/.game-data/baseq2/pak0.pak" ]; then
  echo "[deploy] copying paks from workstation .game-data/ → $HOST:~/Desktop/quake2/baseq2/"
  # First clear any stale symlinks from a previous symlink-mode deploy
  # so rsync writes real files (rsync follows symlinks for source but
  # writes regular files for destination by default, so this is belt-
  # and-suspenders — and also drops dangling links).
  ssh "$HOST" "cd ~/Desktop/quake2/baseq2 && find . -maxdepth 1 -name 'pak*.pak' -type l -delete 2>/dev/null; true"
  rsync -av --partial --checksum $RSYNC_EXTRA \
    -e 'ssh -o ServerAliveInterval=15' \
    "$REPO_ROOT/.game-data/baseq2/pak0.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak1.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak2.pak" \
    "$HOST:Desktop/quake2/baseq2/" | tail -5
elif [ "$(ssh "$HOST" "[ -f '$GAME_DATA_DIR/pak0.pak' ] && echo yes || echo no")" = "yes" ]; then
  # Workstation cache empty but host has paks elsewhere — copy in
  # place via ssh+cp so we don't pull 200 MB across the network just
  # to push it back to the same machine.
  echo "[deploy] copying paks from $HOST:~/$GAME_DATA_DIR/ → ~/Desktop/quake2/baseq2/"
  ssh "$HOST" "cd ~/Desktop/quake2/baseq2 &&
    find . -maxdepth 1 -name 'pak*.pak' -type l -delete 2>/dev/null
    for p in pak0 pak1 pak2; do
      cp -f \"\$HOME/$GAME_DATA_DIR/\$p.pak\" \"\$p.pak\"
    done
    ls -la | grep pak"
else
  echo "deploy.sh: no game data on $HOST and none in .game-data/ — populate one" >&2
  echo "  hint: rsync -av 'quicksilver:Desktop/Quake 2/baseq2/pak*.pak' .game-data/baseq2/" >&2
  exit 1
fi

# Finder bundle recognition. Empirically Tiger / Panther / Lion Finder
# all treat a directory ending in `.app` as a package (single-icon,
# double-clickable bundle) purely by extension, as long as Contents/
# Info.plist resolves CFBundleIconFile to a real .icns. The HFS+
# kHasBundle bit is a Carbon-era leftover for HFS-without-extensions
# and is NOT required on our retro fleet (verified empirically on
# quicksilver Tiger — icon renders without the bit ever being set).
#
# Post-deploy housekeeping:
#   1. chmod +x the binary inside the bundle (rsync occasionally
#      strips the +x bit depending on umask differences)
#   2. touch the bundle + parent dir so Finder invalidates its
#      icon cache and shows the new icon immediately instead of
#      after a mount cycle / login
#
# If a future Mac in the fleet does need the bit (HFS-formatted volume,
# extension-hidden setting, etc.), scripts/bundle/set-bundle-bit.c is
# the documented C helper — compile as a universal binary and ship it.
if [ "$MODE" = "fat" ]; then
  ssh "$HOST" 'APP=~/Desktop/quake2/Quake2.app
    chmod +x "$APP/Contents/MacOS/quake2" 2>/dev/null
    touch "$APP" ~/Desktop/quake2 2>/dev/null || true'
fi

# Post-deploy verification: md5 the engine binary on the target and
# compare to the local source. Catches silent rsync-skipped files
# (we saw this on the QuakeSpasm sister project with a 298 KB stale
# icns left in place by --partial).
case "$MODE" in
  fat)        LOCAL_BIN="$BUILD_DIR/quake2"
              REMOTE_BIN_PATH='~/Desktop/quake2/Quake2.app/Contents/MacOS/quake2' ;;
  per-target) LOCAL_BIN="$BUILD_DIR/quake2"
              REMOTE_BIN_PATH='~/Desktop/quake2/quake2' ;;
esac
LOCAL_BIN_MD5=$(md5sum "$LOCAL_BIN" | awk '{print $1}')
REMOTE_BIN_MD5=$(ssh "$HOST" "if command -v md5 >/dev/null 2>&1; then
  md5 -q $REMOTE_BIN_PATH 2>/dev/null
else
  md5sum $REMOTE_BIN_PATH 2>/dev/null | awk '{print \$1}'
fi")
if [ "$LOCAL_BIN_MD5" != "$REMOTE_BIN_MD5" ]; then
  echo "[deploy] WARN: binary md5 mismatch (local $LOCAL_BIN_MD5 vs remote $REMOTE_BIN_MD5)" >&2
fi

echo "[deploy] OK on $HOST (mode=$MODE, bin=$BIN_TARGET)"
ssh "$HOST" 'ls -la ~/Desktop/quake2/ | head -10'
