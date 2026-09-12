#!/usr/bin/env bash
# Atomically replace an occupied Quake II install from an already-mounted DMG.
# This is the target-side primitive used by deploy-dmg.sh --update. It never
# deletes the old install: success leaves a uniquely named rollback beside the
# new install, while a failed post-publish gate moves the candidate aside and
# restores the original path.

set -euo pipefail

fail() {
  echo "[update-tree] FATAL: $*" >&2
  exit 1
}

file_md5() {
  md5 "$1" 2>/dev/null | awk '{print $NF}'
}

validate_destination() {
  case "$1" in
    /Applications/Quake2) ;;
    *)
      [ "${Q2_UPDATE_ALLOW_TEST_ROOT:-0}" = 1 ] || \
        fail "refusing non-canonical destination: $1"
      ;;
  esac
}

restore_install() {
  ROLLBACK=${1:?usage: update-install-tree.sh --restore <rollback> <destination>}
  DEST=${2:?usage: update-install-tree.sh --restore <rollback> <destination>}
  validate_destination "$DEST"
  [ -d "$DEST/Quake2.app" ] && [ ! -L "$DEST" ] || fail "current install is invalid: $DEST"
  [ -d "$ROLLBACK/Quake2.app" ] && [ ! -L "$ROLLBACK" ] || fail "rollback is invalid: $ROLLBACK"
  [ "$(dirname "$ROLLBACK")" = "$(dirname "$DEST")" ] || fail "restore must stay on one volume"

  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  current_md5=$(file_md5 "$DEST/Quake2.app/Contents/MacOS/quake2")
  rollback_md5=$(file_md5 "$ROLLBACK/Quake2.app/Contents/MacOS/quake2")
  short_current=$(printf '%s' "$current_md5" | cut -c1-12)
  SUPERSEDED="$(dirname "$DEST")/Quake2.superseded-$stamp-$short_current"
  [ ! -e "$SUPERSEDED" ] && [ ! -L "$SUPERSEDED" ] || fail "restore target exists: $SUPERSEDED"

  current_moved=no
  # Invoked indirectly by the EXIT/signal traps below.
  # shellcheck disable=SC2329
  restore_cleanup() {
    if [ "$current_moved" = yes ] && [ ! -e "$DEST" ] && [ -d "$SUPERSEDED" ]; then
      mv "$SUPERSEDED" "$DEST" || true
    fi
  }
  trap restore_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mv "$DEST" "$SUPERSEDED"
  current_moved=yes
  if ! mv "$ROLLBACK" "$DEST"; then
    mv "$SUPERSEDED" "$DEST"
    current_moved=no
    fail "restore rename failed; current install returned to place"
  fi
  if [ "$(file_md5 "$DEST/Quake2.app/Contents/MacOS/quake2")" != "$rollback_md5" ]; then
    FAILED="$(dirname "$DEST")/Quake2.failed-restore-$stamp-$short_current"
    mv "$DEST" "$FAILED"
    mv "$SUPERSEDED" "$DEST"
    current_moved=no
    fail "restored engine failed verification; prior current install returned to place"
  fi
  current_moved=no
  trap - EXIT HUP INT TERM
  echo "[update-tree] restored $DEST"
  echo "SUPERSEDED_PATH=$SUPERSEDED"
  echo "RESTORED_ENGINE_MD5=$rollback_md5"
}

if [ "${1:-}" = --restore ]; then
  shift
  restore_install "$@"
  exit 0
fi

SOURCE=${1:?usage: update-install-tree.sh <mounted-dmg-root> <destination>}
DEST=${2:?usage: update-install-tree.sh <mounted-dmg-root> <destination>}
validate_destination "$DEST"

[ -d "$SOURCE/Quake2.app" ] && [ ! -L "$SOURCE" ] || fail "invalid mounted source: $SOURCE"
[ -d "$DEST/Quake2.app" ] && [ ! -L "$DEST" ] || fail "invalid occupied install: $DEST"
for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  [ -f "$SOURCE/$relative" ] || fail "candidate is missing $relative"
  [ -f "$DEST/$relative" ] || fail "current install is missing $relative"
done

PARENT=$(dirname "$DEST")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
old_md5=$(file_md5 "$DEST/Quake2.app/Contents/MacOS/quake2")
new_md5=$(file_md5 "$SOURCE/Quake2.app/Contents/MacOS/quake2")
short_old=$(printf '%s' "$old_md5" | cut -c1-12)
short_new=$(printf '%s' "$new_md5" | cut -c1-12)
STAGE="$PARENT/.Quake2.stage-$stamp-$$"
BACKUP="$PARENT/Quake2.rollback-$stamp-$short_old"
FAILED="$PARENT/Quake2.failed-update-$stamp-$short_new"
OLD_MANIFEST="${TMPDIR:-/tmp}/q2-update-old.$$.manifest"
NEW_MANIFEST="${TMPDIR:-/tmp}/q2-update-new.$$.manifest"

for path in "$STAGE" "$BACKUP" "$FAILED"; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "refusing occupied update path: $path"
done

needed_kb=$(du -sk "$DEST" | awk '{print $1}')
available_kb=$(df -k "$PARENT" | awk 'NR == 2 {print $4}')
case "$needed_kb" in ''|*[!0-9]*) fail "could not determine update space requirement" ;; esac
case "$available_kb" in ''|*[!0-9]*) fail "could not determine available update space" ;; esac
required_kb=$((needed_kb + 65536))
[ "$available_kb" -ge "$required_kb" ] || \
  fail "not enough free space: need ${required_kb}KB, have ${available_kb}KB"

inventory_baseq2() {
  root=$1
  output=$2
  (
    cd "$root"
    find . -type f ! -path './game.so' -print | LC_ALL=C sort | while IFS= read -r relative; do
      printf '%s  %s\n' "$(file_md5 "$relative")" "$relative"
    done
  ) > "$output"
}

ORIGINAL_MOVED=no
UPDATE_COMPLETE=no
cleanup_before_publish() {
  if [ "$ORIGINAL_MOVED" = yes ] && [ "$UPDATE_COMPLETE" != yes ]; then
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
      if [ ! -e "$FAILED" ] && [ ! -L "$FAILED" ]; then
        mv "$DEST" "$FAILED" || true
      fi
    fi
    if [ ! -e "$DEST" ] && [ ! -L "$DEST" ] && [ -d "$BACKUP" ]; then
      mv "$BACKUP" "$DEST" || true
    fi
  fi
  [ ! -e "$STAGE" ] || rm -rf "$STAGE"
  rm -f "$OLD_MANIFEST" "$NEW_MANIFEST"
}
trap cleanup_before_publish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[update-tree] current=$DEST engine=$old_md5 size=${needed_kb}KB"
echo "[update-tree] stage=$STAGE rollback=$BACKUP"
inventory_baseq2 "$DEST/baseq2" "$OLD_MANIFEST"

ditto "$DEST" "$STAGE"
rm -rf "$STAGE/Quake2.app"
ditto "$SOURCE/Quake2.app" "$STAGE/Quake2.app"

copy_verified() {
  src=$1
  dst=$2
  want=$(file_md5 "$src")
  attempt=1
  while [ "$attempt" -le 4 ]; do
    rm -f "$dst"
    cp -p "$src" "$dst"
    sync
    got=$(file_md5 "$dst")
    [ "$got" = "$want" ] && return 0
    echo "[update-tree] retry $attempt: $dst $got != $want" >&2
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

for relative in ref_gl.so baseq2/game.so q2ded; do
  copy_verified "$SOURCE/$relative" "$STAGE/$relative" || fail "could not verify staged $relative"
done
for relative in README.txt "Fix and Install.command" clear-launch-quarantine.sh; do
  if [ -f "$SOURCE/$relative" ]; then
    copy_verified "$SOURCE/$relative" "$STAGE/$relative" || fail "could not verify staged $relative"
  fi
done

inventory_baseq2 "$STAGE/baseq2" "$NEW_MANIFEST"
cmp -s "$OLD_MANIFEST" "$NEW_MANIFEST" || fail "retained baseq2 data/config differs in stage"

for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  [ "$(file_md5 "$STAGE/$relative")" = "$(file_md5 "$SOURCE/$relative")" ] || \
    fail "staged runtime mismatch: $relative"
done

if [ -f "$STAGE/baseq2/autoexec.cfg" ]; then
  echo "[update-tree] preserved user baseq2/autoexec.cfg; effective cvars require live readback"
  PRESERVED_AUTOEXEC=yes
else
  PRESERVED_AUTOEXEC=no
fi

[ "${Q2_UPDATE_FAIL_STAGE:-0}" != 1 ] || fail "injected pre-promotion failure"

mv "$DEST" "$BACKUP"
ORIGINAL_MOVED=yes
[ "${Q2_UPDATE_FAIL_AFTER_BACKUP:-0}" != 1 ] || fail "injected failure after backup rename"
if ! mv "$STAGE" "$DEST"; then
  mv "$BACKUP" "$DEST"
  ORIGINAL_MOVED=no
  fail "promotion failed; original install restored"
fi
STAGE=

rollback_after_publish() {
  reason=$1
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    mv "$DEST" "$FAILED"
  fi
  if ! mv "$BACKUP" "$DEST"; then
    echo "[update-tree] FATAL: $reason; automatic restore also failed" >&2
    echo "[update-tree] original remains at $BACKUP; failed candidate at $FAILED" >&2
    exit 14
  fi
  ORIGINAL_MOVED=no
  echo "[update-tree] FATAL: $reason; original restored, failed candidate retained at $FAILED" >&2
  exit 13
}

[ "${Q2_UPDATE_FAIL_POSTPUBLISH:-0}" != 1 ] || rollback_after_publish "injected post-promotion failure"
for relative in Quake2.app/Contents/MacOS/quake2 ref_gl.so baseq2/game.so q2ded; do
  [ "$(file_md5 "$DEST/$relative")" = "$(file_md5 "$SOURCE/$relative")" ] || \
    rollback_after_publish "installed runtime mismatch: $relative"
done
if [ -x "$DEST/clear-launch-quarantine.sh" ]; then
  sh "$DEST/clear-launch-quarantine.sh" "$DEST/Quake2.app" || \
    rollback_after_publish "quarantine/LaunchServices setup failed"
fi

rm -f "$OLD_MANIFEST" "$NEW_MANIFEST"
UPDATE_COMPLETE=yes
trap - EXIT HUP INT TERM
echo "[update-tree] update complete"
echo "CURRENT_PATH=$DEST"
echo "ROLLBACK_PATH=$BACKUP"
echo "OLD_ENGINE_MD5=$old_md5"
echo "NEW_ENGINE_MD5=$new_md5"
echo "PRESERVED_AUTOEXEC=$PRESERVED_AUTOEXEC"
