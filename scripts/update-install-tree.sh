#!/usr/bin/env bash
# Atomically replace an occupied Quake II install from an already-mounted DMG.
# This is the target-side primitive used by deploy-dmg.sh --update. Fix
# forward (user rule, 2026-09-23): no rollback copy is kept. The old install is
# held in SWAP_ROOT only for the swap, restored if the candidate fails
# verification, and deleted once the new install verifies. A failed candidate
# is deleted, not kept. A bad release is fixed by deploying a fixed build.

# Panther/Tiger ship Bash 2.05, whose `set` rejects pipefail. Every pipeline in
# this target-side helper is either read-only inventory or checked by its final
# consumer, so errexit + nounset provide the required failure boundary here.
set -eu

fail() {
  echo "[update-tree] FATAL: $*" >&2
  exit 1
}

file_md5() {
  if command -v md5 >/dev/null 2>&1; then
    digest=$(md5 -q "$1") || return 1
  else
    digest=$(md5sum "$1") || return 1
    digest=${digest%% *}
  fi
  [ "${#digest}" = 32 ] || return 1
  case "$digest" in *[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s\n' "$digest"
}

# Keep the native Mac operations on the fleet. GNU equivalents let the real
# update/rollback code run in Linux CI instead of mocking its filesystem work.
device_id() {
  case "$(uname -s)" in
    Darwin)
      if command -v stat >/dev/null 2>&1; then
        stat -f %d "$1"
      else
        # Panther has no stat command; its bundled Perl exposes st_dev.
        perl -e '@s = stat($ARGV[0]); @s or die "stat failed: $!\n"; print "$s[0]\n"' "$1"
      fi
      ;;
    *) stat -c %d "$1" ;;
  esac
}

copy_tree() {
  if command -v ditto >/dev/null 2>&1; then
    ditto "$1" "$2"
  else
    cp -pR "$1" "$2"
  fi
}

# Never /Applications: a copy beside the live install is the launch ambiguity
# and disk weight old-mac-quake2#75 was about. Same volume as /Applications,
# so the swap is a rename. Overridable for the test fixture.
SWAP_ROOT="${Q2_UPDATE_SWAP_ROOT:-$HOME/oldmac/quake2/swap}"
LEGACY_ROLLBACK_ROOT="${Q2_UPDATE_LEGACY_ROOT:-$HOME/oldmac/quake2/rollbacks}"

validate_destination() {
  case "$1" in
    /Applications/Quake2) ;;
    *)
      [ "${Q2_UPDATE_ALLOW_TEST_ROOT:-0}" = 1 ] || \
        fail "refusing non-canonical destination: $1"
      ;;
  esac
}

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
BACKUP="$SWAP_ROOT/Quake2.previous-$stamp-$short_old"
FAILED="$SWAP_ROOT/Quake2.failed-$stamp-$short_new"
OLD_MANIFEST="${TMPDIR:-/tmp}/q2-update-old.$$.manifest"
NEW_MANIFEST="${TMPDIR:-/tmp}/q2-update-new.$$.manifest"

mkdir -p "$SWAP_ROOT"
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
    # Fix forward: the failed candidate is not kept.
    if [ -d "$DEST" ] && [ ! -e "$BACKUP" ]; then rm -rf "$FAILED"; fi
  fi
  [ ! -e "$STAGE" ] || rm -rf "$STAGE"
  rm -f "$OLD_MANIFEST" "$NEW_MANIFEST"
}
trap cleanup_before_publish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[update-tree] current=$DEST engine=$old_md5 size=${needed_kb}KB"
echo "[update-tree] stage=$STAGE swap=$BACKUP"
inventory_baseq2 "$DEST/baseq2" "$OLD_MANIFEST"

copy_tree "$DEST" "$STAGE"
rm -rf "$STAGE/Quake2.app"
copy_tree "$SOURCE/Quake2.app" "$STAGE/Quake2.app"

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
  rm -rf "$FAILED"
  echo "[update-tree] FATAL: $reason; original restored, failed candidate deleted" >&2
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
# Panther keeps LaunchServices under ApplicationServices, unlike later OSes.
# Refresh the current path so Finder does not keep launching the moved backup.
panther_ls=/System/Library/Frameworks/ApplicationServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$panther_ls" ]; then
  "$panther_ls" -f "$DEST/Quake2.app" || rollback_after_publish "LaunchServices registration failed"
fi
UPDATE_COMPLETE=yes
trap - EXIT HUP INT TERM
# Fix forward: the previous install is deleted once the new one verified.
# Also clear anything earlier versions of this script kept (rollbacks,
# failed candidates, superseded restores), so no fleet Mac carries copies.
rm -rf "$BACKUP"
for old in "$SWAP_ROOT"/Quake2.* "$LEGACY_ROLLBACK_ROOT"/Quake2.*; do
  [ -d "$old" ] && [ ! -L "$old" ] || continue
  rm -rf "$old" && echo "[update-tree] removed old copy $(basename "$old")"
done
rmdir "$LEGACY_ROLLBACK_ROOT" 2>/dev/null || true
echo "[update-tree] update complete"
echo "CURRENT_PATH=$DEST"
echo "OLD_ENGINE_MD5=$old_md5"
echo "NEW_ENGINE_MD5=$new_md5"
echo "PRESERVED_AUTOEXEC=$PRESERVED_AUTOEXEC"
