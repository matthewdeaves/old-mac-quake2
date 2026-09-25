#!/usr/bin/env bash
# Deploy the yquake2 fat universal build to a target machine and stage
# game data.
#
# Usage:
#   scripts/deploy.sh <target>
#
# Stages a self-contained Quake2 install and atomically publishes it at
# /Applications/Quake2. An existing destination is refused. The legacy
# ~/quake2-play tree remains untouched as a game-data source.
#   Quake2.app/
#     Contents/Info.plist
#     Contents/MacOS/quake2                  (fat: ppc750 + ppc7400 + ppc970 + i386 + x86_64 + arm64)
#     Contents/MacOS/SDL.framework/          (fat: ppc + ppc970 + i386 + x86_64)
#     Contents/Resources/Quake2.icns
#     Contents/Resources/autoexec-<arch>.cfg × 6      ← per-arch baselines
#     Contents/Resources/autoexec-<machine>.cfg × 9   ← per-machine overlays
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
# Single deploy mode by design. Fat is the only canonical layout now. An update
# needs a separate named-backup flow; this script creates only a fresh install.

set -euo pipefail

TARGET="${1:?usage: $0 <yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|imac-g5|mini-intel|mini-intel2|mini-sl|imac-2019|g5-panther|g5-tiger|g5-desktop|quad-tiger|quad-leopard>}"

# Claim this machine for the whole run. See scripts/shared.sh pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK names the machine claimed further up the chain, which is what
# stops the re-exec below recursing. Compare it against the target rather than
# testing whether it is set: a step that targets a DIFFERENT machine still has
# to claim that one, and the emptiness test skipped it silently. Issue #19.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$TARGET"
	exec "$_PICK" pick-bench-host.sh --run "$TARGET" "deploy" -- "$0" "$@"
fi
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
  yosemite-tiger)
    # The SAME PowerMac1,1 as `yosemite`, booted from its second partition
    # (10.4.11 Tiger). One IP, one OS at a time — switch with `bless --mount
    # /Volumes/<vol> --setBoot` and a reboot. It gets its own target rather
    # than riding on `yosemite` so bench rows record the right OS, but it is
    # NOT a second machine: never drive both at once.
    #
    # No --protocol=29 here. That shim exists for Panther's rsync 2.5.x;
    # Tiger ships 2.6.3, which speaks protocol 29 natively. Note 2.6.3 is
    # still too old for macOS 15's openrsync (which always sends --dirs,
    # rsync 2.6.4+) — use the Homebrew rsync on the orchestrator, see
    # CLAUDE.md.
    #
    # hw.model still reads PowerMac1,1, so the autoexec-yosemite overlay
    # applies unchanged, and the ppc750 slice is min-10.3 so it loads
    # forward onto Tiger.
    HOST=yosemite-tiger
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
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
  imac-g5)
    # PowerMac8,2 — iMac G5, Leopard 10.5.8. Ships the ppc970 fat slice.
    # Leopard rsync is modern enough; no --protocol shim needed (unlike
    # the Panther G3). Game data staged under Desktop/Quake 2/ like the
    # other PPC boxes.
    HOST=imac-g5
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  mini-intel)
    HOST=mini-intel
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  mini-intel2)
    # Same Macmini2,1 / 10.7.5 / toolchain as mini-intel (also a build
    # host — see CLAUDE.md). Missing here entirely until issue #64:
    # deploy.sh had no case for it at all, so it could never receive game
    # data or an app install through this path (only smoke-dmg.sh and
    # screenshot.sh already knew this target). ~/quake2-play is deliberately
    # separate from ~/quake2, this box's build-tree rsync target.
    HOST=mini-intel2
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  mini-sl)
    # Snow Leopard 10.6.8 x86_64 box, added 2026-08-04 (see build-fat.sh).
    # Same gap as mini-intel2 above: no case here until issue #64. Its
    # real legacy game data (measured) lives at Desktop/quake2/baseq2 (no
    # space, lowercase) -- the OLD, pre-#63 install layout -- not the
    # "Games/Quake 2" convention the other Intel boxes use. Only matters
    # as the last-resort fallback below; the canonical .game-data/ source
    # is what actually gets used.
    HOST=mini-sl
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/quake2/baseq2'
    ;;
  imac-2019)
    HOST=imac-2019
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Games/Quake 2/baseq2'
    ;;
  g5-panther)
    # G5 Dual 2.7 (PowerMac7,3), Panther partition. Never had a target
    # here — issue found 2026-08-29: deploy-dmg.sh only PRESERVES existing
    # game data, so a partition that never had this script run against it
    # stays paks-empty forever and the app opens then silently quits on
    # missing pics/colormap.pcx. Panther's rsync 2.5.x needs the same
    # --protocol=29 shim as yosemite.
    HOST=g5-panther
    RSYNC_EXTRA="--protocol=29"
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  g5-tiger)
    # Same PowerMac7,3 as g5-panther/g5-desktop, Tiger partition. One IP,
    # one OS at a time. Tiger's rsync speaks protocol 29 natively.
    HOST=g5-tiger
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  g5-desktop)
    # Same PowerMac7,3, Leopard partition.
    HOST=g5-desktop
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  quad-tiger)
    # G5 Quad, Tiger partition.
    HOST=quad-tiger
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  quad-leopard)
    # Same G5 Quad, Leopard partition.
    HOST=quad-leopard
    RSYNC_EXTRA=""
    GAME_DATA_DIR='Desktop/Quake 2/baseq2'
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

BUILD_DIR="$REPO_ROOT/build/q2-fat"
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/quake2" ]; then
  echo "deploy.sh: build/q2-fat not found — run scripts/build-fat.sh first" >&2
  exit 1
fi

if ssh "$HOST" '[ ! -e /Applications/Quake2 ] && [ ! -L /Applications/Quake2 ]'; then
  OCCUPIED=no
else
  OCCUPIED=yes
  echo "[deploy $HOST] /Applications/Quake2 already exists — upgrading the runtime in place (#72)"
fi

# Stage layout locally, then rsync. Using a temp dir means we can ship
# symlinks to SDL.framework slices cleanly without rsync flattening
# them on the way out.
STAGE=$(mktemp -d -t q2-deploy.XXXXXX)
REMOTE_STAGE=""
cleanup_deploy() {
  rm -rf "$STAGE"
  if [ -n "$REMOTE_STAGE" ]; then
    ssh "$HOST" "rm -rf '$REMOTE_STAGE'; rm -f .q2-clear-launch-quarantine.sh" >/dev/null 2>&1 || true
  fi
}
trap cleanup_deploy EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[deploy] stage Quake2.app bundle"
APP="$STAGE/Quake2.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/baseq2"
cp "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"

# Stamp the PORT release version into the bundle so a human can tell which
# build is installed from Finder's Get Info, not just from the engine
# console. The static plist carries upstream's engine version (5.11), which
# never changes between our releases and so identifies nothing.
Q2_PORT_VERSION="${Q2_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 5.11-oldmac-$Q2_PORT_VERSION" \
  -c "Add :CFBundleVersion string $Q2_PORT_VERSION" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 5.11-oldmac-$Q2_PORT_VERSION" \
  -c "Set :CFBundleVersion $Q2_PORT_VERSION" \
  "$APP/Contents/Info.plist" >/dev/null
echo "[deploy] bundle version: 5.11-oldmac-$Q2_PORT_VERSION"

cp "$REPO_ROOT/MacOSX/Quake2.icns"        "$APP/Contents/Resources/"
cp "$BUILD_DIR/quake2"                    "$APP/Contents/MacOS/"
cp -a "$REPO_ROOT/MacOSX/SDL.framework"   "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/quake2"

# The arm64 member of that framework is sdl12-compat, which dlopen()s a real
# SDL2 at runtime from beside the executable. Ship ours so that is what it
# finds. Inert on PowerPC and Intel, which link genuine SDL 1.2 and never open
# it. Optional, exactly like the arm64 slice. docs/adr/0015.
if [ -f "$BUILD_DIR/libSDL2-2.0.0.dylib" ]; then
  cp "$BUILD_DIR/libSDL2-2.0.0.dylib"     "$APP/Contents/MacOS/"
  echo "[deploy] staged libSDL2-2.0.0.dylib for the arm64 slice"
fi

# Per-machine autoexec cfgs ship INSIDE the .app bundle. The engine
# (yquake2/src/common/misc.c:Qcommon_Init) reads the matching one at
# boot via CFBundle + sysctl hw.model, layered AFTER the standard
# default.cfg → yq2.cfg → config.cfg chain so it always wins.
#
# Two cfg layers ship in every deploy (regardless of $TARGET) so the
# bundle is self-contained and machine-portable — dropping the .app onto
# ANY G3/G4/G5/Intel/Apple Silicon Mac works without redeployment:
#   * per-arch baselines (ppc750/ppc7400/ppc970/i386/x86_64/arm64) — picked at
#     compile time by the fat slice dyld runs; the "sane generic on
#     everything else" floor for machines not in the hw.model map.
#   * per-machine overlays (the six fleet boxes) — picked at runtime by
#     sysctl hw.model, layered on top so known machines stay hand-tuned.
#
# Bench compatibility: the overlays DO set gl_mode / gl_customwidth /
# gl_customheight / vid_fullscreen now, but the bundle hook runs AFTER the
# initial VID_Init (post-CL_Init) and never vid_restarts, so those only
# take effect on the NEXT launch — they don't colour a running bench, which
# sets its mode via cmdline +set. (bench.sh also has -noarchautoexec.)
#
# CRITICAL: the cfgs are shipped COMMENT-STRIPPED. The engine appends each
# cfg to a fixed 8 KB command buffer (cmd_text_buf[8192], cmdparser.c). The
# per-arch baseline + per-machine overlay are Cbuf_AddText'd back-to-back
# before execution, so their COMBINED size must stay well under 8 KB. With
# their documentation comments the two files together exceeded 8 KB on every
# machine → "Cbuf_AddText: overflow", which dropped/garbled the overlay and
# (on the iMac G5's R300 driver) wedged the GPU on map load. Stripping the
# `//` comments + blank lines leaves only the `set` lines (~1-2 KB each),
# a wide margin. (v2.2.0 shipped un-stripped and hit this; fixed v2.2.1.)
for cfg in controls \
           ppc750 ppc7400 ppc970 i386 x86_64 arm64 \
           yosemite sawtooth quicksilver mini-g4 imac-g5 imac-g4 mini-intel imac-2019 g5-dual gpu-r300-g5; do
  sed -e 's,//.*,,' -e 's/[[:space:]]*$//' \
      "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" \
    | grep -v '^[[:space:]]*$' \
    > "$APP/Contents/Resources/autoexec-$cfg.cfg"
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
# = /Applications/Quake2/ and Q2 finds ref_gl.so there. baseq2/ lives
# in the same dir for the same reason — Q2's gamedir search walks
# basedir/baseq2/ for game.so + paks.
cp "$BUILD_DIR/ref_gl.so"                 "$STAGE/"
cp "$BUILD_DIR/baseq2/game.so"            "$STAGE/baseq2/"
cp "$BUILD_DIR/q2ded"                     "$STAGE/" 2>/dev/null || true
[ -f "$STAGE/q2ded" ] && chmod +x "$STAGE/q2ded"

REMOTE_DEST="/Applications/Quake2"
REMOTE_STAGE="/Applications/.Quake2.stage.$$"
case "$REMOTE_STAGE" in
  /Applications/.Quake2.stage.[0-9]*) ;;
  *) echo "[deploy] unsafe staging path: $REMOTE_STAGE" >&2; exit 3 ;;
esac

if [ "$OCCUPIED" = no ]; then
  echo "[deploy] prepare $HOST:$REMOTE_STAGE"
  ssh "$HOST" "set -e
    DEST='$REMOTE_DEST'
    STAGE='$REMOTE_STAGE'
    LEGACY=\"\$HOME/$GAME_DATA_DIR\"
    [ ! -e \"\$DEST\" ] && [ ! -L \"\$DEST\" ] || { echo 'REFUSE: /Applications/Quake2 already exists' >&2; exit 10; }
    [ ! -e \"\$STAGE\" ] && [ ! -L \"\$STAGE\" ] || { echo 'REFUSE: staging path exists' >&2; exit 11; }
    mkdir \"\$STAGE\"
    if [ -d \"\$HOME/quake2-play/baseq2\" ]; then
      ditto \"\$HOME/quake2-play/baseq2\" \"\$STAGE/baseq2\"
      echo '[deploy] copied ~/quake2-play/baseq2; source left untouched'
    elif [ -d \"\$LEGACY\" ]; then
      ditto \"\$LEGACY\" \"\$STAGE/baseq2\"
      echo '[deploy] copied the host legacy baseq2; source left untouched'
    else
      mkdir \"\$STAGE/baseq2\"
    fi
    rm -f \"\$STAGE/baseq2/autoexec.cfg\""
else
  # #72: DEST is occupied. Its baseq2 game data stays where it is, and only
  # the runtime is swapped at publish time, so stage nothing but the runtime.
  echo "[deploy] prepare $HOST:$REMOTE_STAGE (occupied — game data comes from the live install, #72)"
  ssh "$HOST" "set -e
    STAGE='$REMOTE_STAGE'
    [ ! -e \"\$STAGE\" ] && [ ! -L \"\$STAGE\" ] || { echo 'REFUSE: staging path exists' >&2; exit 11; }
    mkdir \"\$STAGE\"
    mkdir \"\$STAGE/baseq2\""
fi

# Transfer only the owned runtime products. --delete is scoped to the staged app
# bundle, never the destination root or copied game data.
rsync -av --partial --checksum --delete $RSYNC_EXTRA \
  -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/Quake2.app/" "$HOST:$REMOTE_STAGE/Quake2.app/" | tail -8
for rel in ref_gl.so baseq2/game.so q2ded; do
  [ -f "$STAGE/$rel" ] || continue
  rsync -a --partial --checksum $RSYNC_EXTRA \
    -e 'ssh -o ServerAliveInterval=15' \
    "$STAGE/$rel" "$HOST:$REMOTE_STAGE/$rel"
done

# Overlay the canonical workstation game data when present, while retaining all
# other copied legacy content such as saves, mods, video and custom assets.
# #72: skipped when occupied; the live install keeps its own game data.
if [ "$OCCUPIED" = yes ]; then
  :
elif [ -f "$REPO_ROOT/.game-data/baseq2/pak0.pak" ]; then
  ssh "$HOST" "cd '$REMOTE_STAGE/baseq2' && find . -maxdepth 1 -name 'pak*.pak' -type l -delete 2>/dev/null; true"
  rsync -av --partial --checksum $RSYNC_EXTRA \
    -e 'ssh -o ServerAliveInterval=15' \
    "$REPO_ROOT/.game-data/baseq2/pak0.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak1.pak" \
    "$REPO_ROOT/.game-data/baseq2/pak2.pak" \
    "$HOST:$REMOTE_STAGE/baseq2/" | tail -5
  if [ -d "$REPO_ROOT/.game-data/baseq2/players" ]; then
    rsync -a --partial --checksum $RSYNC_EXTRA \
      -e 'ssh -o ServerAliveInterval=15' \
      "$REPO_ROOT/.game-data/baseq2/players/" \
      "$HOST:$REMOTE_STAGE/baseq2/players/" | tail -3
  fi
elif [ "$(ssh "$HOST" "[ -f '$REMOTE_STAGE/baseq2/pak0.pak' ] && echo yes || echo no")" != yes ]; then
  echo "deploy.sh: no game data copied on $HOST and none in .game-data/" >&2
  echo "  populate .game-data/baseq2 or the host's legacy install first" >&2
  exit 1
fi

ssh "$HOST" "rm -f '$REMOTE_STAGE/baseq2/autoexec.cfg'; test ! -e '$REMOTE_STAGE/baseq2/autoexec.cfg'"

verify_staged_file() {
  local rel="$1" want got
  want=$(md5sum "$STAGE/$rel" | awk '{print $1}')
  got=$(ssh "$HOST" "md5 -q '$REMOTE_STAGE/$rel' 2>/dev/null")
  [ "$want" = "$got" ] || {
    echo "[deploy] FATAL: staged $rel differs from local bytes ($want != $got)" >&2
    exit 7
  }
}
verify_staged_file Quake2.app/Contents/MacOS/quake2
verify_staged_file ref_gl.so
verify_staged_file baseq2/game.so
[ ! -f "$STAGE/q2ded" ] || verify_staged_file q2ded
echo "[deploy] staged runtime binaries match the local build byte-for-byte"

# clear-launch-quarantine.sh must exist as a real local file to scp onto the
# target and run there -- scripts/shared.sh only fetches-and-execs locally, it
# has no "just give me the path" mode. Warm its pin cache the same way
# shared.sh would (any invocation populates the cache before shared.sh execs
# it, so a deliberately-wrong arg count -- exit 2, usage message -- still
# leaves the file behind), then scp the cached copy directly.
"$REPO_ROOT/scripts/shared.sh" clear-launch-quarantine.sh >/dev/null 2>&1 || true
CLQ_PIN="$(tr -d '[:space:]' < "$REPO_ROOT/shared-scripts.pin")"
CLQ_BUILDHOST="${OLDMAC_BUILDHOST_REPO:-$REPO_ROOT/../old-mac-build-host}"
CLQ_SHA="$(git -C "$CLQ_BUILDHOST" rev-parse --verify -q "${CLQ_PIN}^{commit}")"
CLQ_LOCAL="${RETRO_SHARED_CACHE:-$HOME/.cache/retro-shared}/$CLQ_SHA/clear-launch-quarantine.sh"
scp -pq "$CLQ_LOCAL" "$HOST:.q2-clear-launch-quarantine.sh"
ssh "$HOST" "set -e
  STAGE='$REMOTE_STAGE'
  chmod +x \"\$STAGE/Quake2.app/Contents/MacOS/quake2\" 2>/dev/null
  sh \"\$HOME/.q2-clear-launch-quarantine.sh\" \"\$STAGE/Quake2.app\"
  rm -f \"\$HOME/.q2-clear-launch-quarantine.sh\""

if [ "$OCCUPIED" = no ]; then
  ssh "$HOST" "set -e
    DEST='$REMOTE_DEST'
    STAGE='$REMOTE_STAGE'
    [ ! -e \"\$DEST\" ] && [ ! -L \"\$DEST\" ] || { echo 'REFUSE: destination appeared during staging' >&2; exit 10; }
    mv \"\$STAGE\" \"\$DEST\"
    touch \"\$DEST/Quake2.app\" \"\$DEST\" 2>/dev/null || true"
else
  # Occupied: replace only the runtime this script owns, fix forward (no
  # copy kept), and leave baseq2's game data and every other file alone. The
  # stage is on the same volume, so each move is a rename.
  ssh "$HOST" "set -e
    DEST='$REMOTE_DEST'
    STAGE='$REMOTE_STAGE'
    for rel in Quake2.app ref_gl.so q2ded baseq2/game.so; do
      [ -e \"\$STAGE/\$rel\" ] || continue
      rm -rf \"\$DEST/\$rel\"
      mv \"\$STAGE/\$rel\" \"\$DEST/\$rel\"
    done
    rm -rf \"\$STAGE\"
    touch \"\$DEST/Quake2.app\" \"\$DEST\" 2>/dev/null || true"
  echo "[deploy] upgraded in place; game data untouched, no rollback kept"
fi
REMOTE_STAGE=""

LOCAL_BIN_MD5=$(md5sum "$BUILD_DIR/quake2" | awk '{print $1}')
REMOTE_BIN_MD5=$(ssh "$HOST" "md5 -q '$REMOTE_DEST/Quake2.app/Contents/MacOS/quake2' 2>/dev/null")
[ "$LOCAL_BIN_MD5" = "$REMOTE_BIN_MD5" ] || {
  echo "[deploy] FATAL: published binary md5 mismatch ($LOCAL_BIN_MD5 != $REMOTE_BIN_MD5)" >&2
  exit 7
}

echo "[deploy] OK on $HOST at $REMOTE_DEST"
ssh "$HOST" "ls -la '$REMOTE_DEST' | head -10"
