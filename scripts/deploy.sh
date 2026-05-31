#!/usr/bin/env bash
# Deploy the yquake2 fat universal build to a target machine and stage
# game data.
#
# Usage:
#   scripts/deploy.sh <target>
#
# Ships a self-contained Quake2.app bundle to ~/Desktop/quake2/:
#   Quake2.app/
#     Contents/Info.plist
#     Contents/MacOS/quake2                  (fat: ppc750 + ppc7400 + ppc970 + x86_64)
#     Contents/MacOS/SDL.framework/          (fat: ppc + i386 + x86_64)
#     Contents/Resources/Quake2.icns
#     Contents/Resources/autoexec-<arch>.cfg × 4      ← per-arch baselines
#     Contents/Resources/autoexec-<machine>.cfg × 6   ← per-machine overlays
#   ref_gl.so                                ← outside .app (Q2's basedir=.)
#   baseq2/
#     game.so                                ← outside .app (Q2's gamedir)
#     pak0.pak, pak1.pak, pak2.pak           ← user-supplied retail content
#
# Everything except the .pak files travels inside Quake2.app. End-user
# install is: drop Quake2.app + their own baseq2/pak*.pak into any
# folder. The bundled per-machine cfg is picked at boot via CFBundle
# (sysctl hw.model in Qcommon_Init) — see yquake2/src/common/misc.c.
#
# Single deploy mode by design: the previous per-target/fat dual mode
# both wrote to ~/Desktop/quake2/ with rsync --delete, so running the
# wrong one clobbered the .app. Fat is the only canonical layout now.
#
# Idempotent — safe to re-run.

set -euo pipefail

TARGET="${1:?usage: $0 <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$TARGET" in
  yosemite)
    # PowerMac1,1 — only G3 / Panther target. Panther ships rsync 2.5.x
    # which doesn't speak modern wire protocol; --protocol=29 is the
    # max it'll accept from a newer client. (QuakeSpasm hit the same.)
    HOST=yosemite
    RSYNC_EXTRA="--protocol=29"
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'   # we'll create this if missing
    ;;
  sawtooth)
    HOST=sawtooth
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  quicksilver)
    HOST=quicksilver
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  mini-g4)
    HOST=mini-g4
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  mini-intel)
    HOST=mini-intel
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  imac-2019)
    HOST=imac-2019
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BUILD_DIR="$REPO_ROOT/build/q2-fat"
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "deploy.sh: build/q2-fat not found — run scripts/build-fat.sh first" >&2
  exit 1
fi

# Stage layout locally, then rsync. Using a temp dir means we can ship
# symlinks to SDL.framework slices cleanly without rsync flattening
# them on the way out.
STAGE=$(mktemp -d -t q2-deploy.XXXXXX)
trap "rm -rf '$STAGE'" EXIT

echo "[deploy] stage Quake2.app bundle"
APP="$STAGE/Quake2.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/baseq2"
cp "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/MacOSX/Quake2.icns"        "$APP/Contents/Resources/"
cp "$BUILD_DIR/quake2"                    "$APP/Contents/MacOS/"
cp -a "$REPO_ROOT/MacOSX/SDL.framework"   "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/quake2"

# Per-machine autoexec cfgs ship INSIDE the .app bundle. The engine
# (yquake2/src/common/misc.c:Qcommon_Init) reads the matching one at
# boot via CFBundle + sysctl hw.model, layered AFTER the standard
# default.cfg → yq2.cfg → config.cfg chain so it always wins.
#
# Two cfg layers ship in every deploy (regardless of $TARGET) so the
# bundle is self-contained and machine-portable — dropping the .app onto
# ANY G3/G4/G5/Intel Mac works without redeployment:
#   * per-arch baselines (ppc750/ppc7400/ppc970/x86_64) — picked at
#     compile time by the fat slice dyld runs; the "sane generic on
#     everything else" floor for machines not in the hw.model map.
#   * per-machine overlays (the six fleet boxes) — picked at runtime by
#     sysctl hw.model, layered on top so known machines stay hand-tuned.
#
# Bench compatibility: the cfgs deliberately do NOT set gl_mode /
# gl_customwidth / gl_customheight / gl_swapinterval. bench.sh relies
# on `+set` for its per-resolution sweep, and uses -noarchautoexec to
# suppress the hook entirely when it needs full cvar control.
for cfg in ppc750 ppc7400 ppc970 x86_64 \
           yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019; do
  cp "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" "$APP/Contents/Resources/"
done

# Procedural decal textures (built by scripts/gen-decals.py, GPL-clean —
# our own work, no id1 EULA constraint). Ship inside the bundle at
# Resources/decals/ so the renderer's R_FindImage("decals/bullet.tga")
# finds them via the CFBundle HD-pak search path. User can override any
# by dropping their own .tga into baseq2/decals/ — gamedir wins.
if [ -d "$REPO_ROOT/yquake2/baseq2-extra/decals" ]; then
  mkdir -p "$APP/Contents/Resources/hd-pak/decals"
  cp "$REPO_ROOT/yquake2/baseq2-extra/decals/"*.tga \
     "$APP/Contents/Resources/hd-pak/decals/"
fi

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

# Migration: previous deploys staged the per-machine cfg to
# baseq2/autoexec.cfg and the engine picked it up via the gamedir fs.
# It now ships inside Quake2.app/Contents/Resources/ and is loaded via
# CFBundle. Wipe the stale file so the user doesn't end up with an
# orphan baseq2/autoexec.cfg that won't be updated by future deploys.
ssh "$HOST" 'rm -f ~/Desktop/quake2/baseq2/autoexec.cfg 2>/dev/null' || true

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
ssh "$HOST" 'APP=~/Desktop/quake2/Quake2.app
  chmod +x "$APP/Contents/MacOS/quake2" 2>/dev/null
  touch "$APP" ~/Desktop/quake2 2>/dev/null || true'

# Post-deploy verification: md5 the engine binary on the target and
# compare to the local source. Catches silent rsync-skipped files
# (we saw this on the QuakeSpasm sister project with a 298 KB stale
# icns left in place by --partial).
LOCAL_BIN="$BUILD_DIR/quake2"
REMOTE_BIN_PATH='~/Desktop/quake2/Quake2.app/Contents/MacOS/quake2'
LOCAL_BIN_MD5=$(md5sum "$LOCAL_BIN" | awk '{print $1}')
REMOTE_BIN_MD5=$(ssh "$HOST" "if command -v md5 >/dev/null 2>&1; then
  md5 -q $REMOTE_BIN_PATH 2>/dev/null
else
  md5sum $REMOTE_BIN_PATH 2>/dev/null | awk '{print \$1}'
fi")
if [ "$LOCAL_BIN_MD5" != "$REMOTE_BIN_MD5" ]; then
  echo "[deploy] WARN: binary md5 mismatch (local $LOCAL_BIN_MD5 vs remote $REMOTE_BIN_MD5)" >&2
fi

echo "[deploy] OK on $HOST"
ssh "$HOST" 'ls -la ~/Desktop/quake2/ | head -10'
