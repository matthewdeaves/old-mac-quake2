#!/usr/bin/env bash
# deploy-dmg.sh -- install a port's release DMG onto a fleet Mac, the way a
# player would get it: the same .dmg, mounted, its app copied into
# /Applications/<Game>/. CANONICAL copy lives in old-mac-build-host (#96) and is
# synced byte-identical into each port; never edit a port's copy. Per-port
# differences live in that port's scripts/dmg-port.conf (and, rarely,
# scripts/dmg-hooks.sh), which are the port's own files and never synced.
#
# usage: scripts/deploy-dmg.sh <host> [version | path/to.dmg]
#        scripts/deploy-dmg.sh --update <host> <version>   (same as the above)
#   host     any fleet alias, or `workstation` (this Mac, no ssh)
#   version  e.g. v1.2.0 -> dist/<DMG_PREFIX>v1.2.0.dmg; default: newest in dist/
#
# What it guarantees, each taken from the port that already did it best:
#  - claims the host for the whole run (re-exec under pick-bench-host.sh --run)
#  - md5-checks the DMG after transfer, and each VERIFY file after install
#  - keeps ALL its state under ~/oldmac/<port>/deploy/ (incoming, mount.<pid>,
#    stage), and removes it when done: one directory a port's build mirror can exclude: on the
#    Lion minis ~/oldmac/<port> is also an rsync --delete build tree (quake2#81)
#  - mounts read-only at a unique deploy/mount.<pid>, and detaches BY
#    DEVICE: Panther's hdiutil ignores a mount path, so path detaches leaked an
#    image per deploy there (quake3 eb3a4eb7, measured on g5-panther)
#  - replaces ONLY the OWNED paths. Game data (DATA_DIR) and anything other
#    scripts put in the install folder are never touched. An optional OWNED
#    path missing from the new image is removed, so a stale BUILD-INFO or README
#    does not outlive its release (halflife 4175fcf).
#  - keeps NO rollback. User rule, 2026-09-23: "we dont need roll backs we
#    should take a fix forward approach". The replaced files are deleted in the
#    same run, and a bad install is fixed by deploying a fixed build.
#
# PRESTAGE=1 mounts the image on THIS Mac and rsyncs its contents across,
# for a host whose own hdiutil attach fails (quad-tiger, DI_kextDriveActivate
# after a fresh boot: halflife 2d46f0f). Everything after the mount is the same.
#
# Exit: 0 ok, 1 failed, 2 usage/config, 6 image would not mount,
#       7 installed files failed verification (fix forward: redeploy),
#       9 the game is running there (FORCE=1 overrides)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
usage() { sed -n '9,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE=install
case "${1:-}" in
	--update)   shift ;;
	--rollback) echo "deploy-dmg: there are no rollbacks (user rule 2026-09-23: fix forward). Deploy a fixed build." >&2; exit 2 ;;
	-h|--help|'') usage ;;
esac
HOST="${1:-}"; [ -n "$HOST" ] || usage
ARG="${2:-}"

# --- port config ----------------------------------------------------------------
CONF="${DMG_PORT_CONF:-$SELF_DIR/dmg-port.conf}"
[ -r "$CONF" ] || { echo "deploy-dmg: no port config at $CONF (see old-mac-build-host#96)" >&2; exit 2; }
IMAGE_ROOT=.; DATA_DIR=; FIRST_SEED=(); PROC=; OWNED=(); VERIFY=(); REMOVE=()
REMOTE_POST_STAGE=; REMOTE_POST_INSTALL=
# shellcheck source=/dev/null
. "$CONF"
[ -r "$SELF_DIR/dmg-hooks.sh" ] && . "$SELF_DIR/dmg-hooks.sh"
for v in PORT DMG_PREFIX INSTALL_DIR; do
	[ -n "${!v:-}" ] || { echo "deploy-dmg: $CONF must set $v" >&2; exit 2; }
done
[ "${#OWNED[@]}" -gt 0 ] || { echo "deploy-dmg: $CONF must list OWNED paths" >&2; exit 2; }
INSTALL_DIR="${DEST_DIR:-$INSTALL_DIR}"   # halflife's DEST_DIR still works
case "$PORT" in *[!a-z0-9-]*|'') echo "deploy-dmg: PORT must be [a-z0-9-]" >&2; exit 2 ;; esac

# --- claim the host for the whole run -------------------------------------------
# Re-exec under the picker, so the lock belongs to the invocation and is
# released however this exits. RETRO_BENCH_LOCK names the host already held, so
# a nested call on the SAME host does not deadlock on its own claim.
_PICK="$SELF_DIR/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "$PORT deploy-dmg $MODE" -- "$0" "$@"
fi

say()  { echo "[deploy-dmg $HOST] $*"; }
die()  { echo "[deploy-dmg $HOST] FATAL: $1" >&2; exit "${2:-1}"; }
lmd5() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
if [ "$HOST" = workstation ]; then
	run_host() { bash -s; }
	put()      { cp "$1" "$HOME/$2"; }
else
	run_host() { ssh "${SSH_OPTS[@]}" "$HOST" bash -s; }
	put()      { scp -q "${SSH_OPTS[@]}" "$1" "$HOST:$2"; }
fi

# Everything the remote body needs, as quoted assignments ahead of it, so paths
# with spaces ("Half-Life Mods.app") survive and nothing is re-parsed.
qarr() { local n="$1"; shift; printf '%s=(' "$n"; [ $# -gt 0 ] && printf ' %q' "$@"; printf ' )\n'; }
header() {
	printf 'MODE=%q HOST=%q PORT=%q DEST=%q IMAGE_ROOT=%q DATA_DIR=%q PROC=%q FORCE=%q DMG_BASE=%q PRESTAGE=%q\n' \
		"$MODE" "$HOST" "$PORT" "$INSTALL_DIR" "$IMAGE_ROOT" "$DATA_DIR" "$PROC" "${FORCE:-0}" "${DMG_BASE:-}" "${PRESTAGE:-0}"
	qarr FIRST_SEED ${FIRST_SEED[@]+"${FIRST_SEED[@]}"}
	qarr OWNED "${OWNED[@]}"
	qarr VERIFY ${VERIFY[@]+"${VERIFY[@]}"}
	qarr REMOVE ${REMOVE[@]+"${REMOVE[@]}"}
	qarr EXPECT ${EXPECT[@]+"${EXPECT[@]}"}
	printf 'POST_STAGE=%q\nPOST_INSTALL=%q\n' "$REMOTE_POST_STAGE" "$REMOTE_POST_INSTALL"
}

# --- the DMG ----------------------------------------------------------------------
if [ "$MODE" = install ]; then
	if [ -n "$ARG" ] && [ -f "$ARG" ]; then DMG="$ARG"
	elif [ -n "$ARG" ]; then DMG="$REPO_ROOT/dist/${DMG_PREFIX}${ARG}.dmg"
	else DMG="$(ls -t "$REPO_ROOT"/dist/"${DMG_PREFIX}"*.dmg 2>/dev/null | head -1)"
	fi
	[ -n "$DMG" ] && [ -f "$DMG" ] || die "no DMG (${ARG:-newest dist/${DMG_PREFIX}*.dmg})" 2
	DMG_BASE="$(basename "$DMG")"

	# A port's local checks run on a PRIVATE clone of the image, never the
	# shared dist/ file: two updates from one Mac used to collide on one mount
	# (quake2 9a387c0a).
	if declare -F preflight_local >/dev/null; then
		CLONE="$(mktemp -d "${TMPDIR:-/tmp}/buildhost-dmgpre.XXXXXX")" || die "mktemp"
		cp "$DMG" "$CLONE/img.dmg" && mkdir "$CLONE/mnt" || die "clone for preflight"
		PDEV="$(hdiutil attach -nobrowse -readonly -mountpoint "$CLONE/mnt" "$CLONE/img.dmg" | awk '/^\/dev\//{sub(/s[0-9]+$/,"",$1); print $1; exit}')"
		[ -n "$PDEV" ] || { rm -rf "$CLONE"; die "preflight: image would not mount locally" 6; }
		preflight_local "$CLONE/mnt"; prc=$?
		hdiutil detach "$PDEV" >/dev/null 2>&1 || hdiutil detach -force "$PDEV" >/dev/null 2>&1
		rm -rf "$CLONE"
		[ $prc -eq 0 ] || die "preflight_local refused $DMG_BASE (rc=$prc)" 1
	fi

	echo "mkdir -p \"\$HOME/oldmac/$PORT/deploy/incoming\"" | run_host || die "cannot reach $HOST"
	EXPECT=()
	if [ "${PRESTAGE:-0}" = 1 ]; then
		CLONE="$(mktemp -d "${TMPDIR:-/tmp}/buildhost-prestage.XXXXXX")" || die "mktemp"
		cp "$DMG" "$CLONE/img.dmg" && mkdir "$CLONE/mnt" || die "clone for prestage"
		PDEV="$(hdiutil attach -nobrowse -readonly -mountpoint "$CLONE/mnt" "$CLONE/img.dmg" | awk '/^\/dev\//{sub(/s[0-9]+$/,"",$1); print $1; exit}')"
		[ -n "$PDEV" ] || { rm -rf "$CLONE"; die "prestage: image would not mount locally" 6; }
		# The host checks what it received against hashes taken from the image here.
		for v in ${VERIFY[@]+"${VERIFY[@]}"}; do
			if [ "$IMAGE_ROOT" = '*' ]; then EXPECT[${#EXPECT[@]}]=-
			elif [ -e "$CLONE/mnt/$IMAGE_ROOT/$v" ]; then EXPECT[${#EXPECT[@]}]="$(lmd5 "$CLONE/mnt/$IMAGE_ROOT/$v")"
			else EXPECT[${#EXPECT[@]}]=-; fi
		done
		say "PRESTAGE: copying the mounted image's contents to ~/oldmac/$PORT/deploy/prestage"
		if [ "$HOST" = workstation ]; then
			rsync -a --delete "$CLONE/mnt/" "$HOME/oldmac/$PORT/deploy/prestage/"; prc=$?
		else
			rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "$CLONE/mnt/" "$HOST:oldmac/$PORT/deploy/prestage/"; prc=$?
		fi
		hdiutil detach "$PDEV" >/dev/null 2>&1 || hdiutil detach -force "$PDEV" >/dev/null 2>&1
		rm -rf "$CLONE"
		[ $prc -eq 0 ] || die "prestage copy failed (rsync rc=$prc)"
	else
		LMD5="$(lmd5 "$DMG")"
		say "copy $DMG_BASE ($LMD5) to ~/oldmac/$PORT/deploy/incoming"
		put "$DMG" "oldmac/$PORT/deploy/incoming/$DMG_BASE" || die "copy failed"
		RMD5="$(printf 'f=%q\n%s\n' "oldmac/$PORT/deploy/incoming/$DMG_BASE" \
			'cd; md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d" " -f1' | run_host)"
		[ "$LMD5" = "$RMD5" ] || die "DMG damaged in transfer ($LMD5 != ${RMD5:-none})"
		say "DMG arrived intact"
	fi
fi

# --- on the host --------------------------------------------------------------------
{ header; cat <<'REMOTE'
set -u
ROOT="$HOME/oldmac/$PORT/deploy"
case "$DEST" in "~/"*) DEST="$HOME/${DEST#"~/"}" ;; esac   # tests install under ~, never /Applications
say()  { echo "  $*"; }
die()  { echo "  FATAL: $1" >&2; exit "${2:-1}"; }
hmd5() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# By device, never by path (Panther ignores a path). 5 tries, then force, then say so.
detach() {
	local d="$1" i=0
	[ -n "$d" ] || return 0
	while [ $i -lt 5 ]; do hdiutil detach "$d" >/dev/null 2>&1 && return 0; i=$((i+1)); sleep 1; done
	hdiutil detach -force "$d" >/dev/null 2>&1 && return 0
	echo "  WARN: $d is still attached" >&2; return 1
}
running() {
	[ -n "$PROC" ] || return 1
	ps -axco command 2>/dev/null | grep -qx "$PROC"
}
if running && [ "$FORCE" != 1 ]; then
	die "$PROC is running on this Mac; not replacing it under a live game (FORCE=1 overrides)" 9
fi
mkdir -p "$ROOT"

# Our own mounts left by an interrupted run: detach them by device first.
mount | while read -r line; do
	mp="${line#* on }"; mp="${mp% (*}"
	d="${line%% on *}"; d="${d%s[0-9]*}"   # the whole disk, not the mounted slice
	case "$mp" in "$ROOT"/mount.*) detach "$d"; rmdir "$mp" 2>/dev/null ;; esac
done

# OLD holds the replaced files only while the swap runs; it is deleted either way.
MNT="$ROOT/mount.$$"; STAGE="$ROOT/stage.$$"; OLD="$ROOT/old.$$"
DEV=
cleanup() { detach "$DEV"; rmdir "$MNT" 2>/dev/null; rm -rf "$STAGE" "$OLD"; rmdir "$ROOT/incoming" "$ROOT" 2>/dev/null; }
trap cleanup EXIT
if [ "$PRESTAGE" = 1 ]; then
	MNT="$ROOT/prestage"; [ -d "$MNT" ] || die "no prestaged image contents" 1
else
	mkdir -p "$MNT"
	DEV="$(hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$ROOT/incoming/$DMG_BASE" 2>/dev/null | awk '/^\/dev\//{sub(/s[0-9]+$/,"",$1); print $1; exit}')"
	[ -n "$DEV" ] || die "hdiutil attach gave no device for $DMG_BASE" 6
fi
# The hash a VERIFY file must have: from this Mac's mount, or (PRESTAGE) the
# invoking Mac's, so a damaged rsync cannot vouch for itself.
want() { local i=0 v; for v in ${VERIFY[@]+"${VERIFY[@]}"}; do
	if [ "$v" = "$1" ]; then [ -n "${EXPECT[$i]:-}" ] && [ "${EXPECT[$i]}" != - ] && { echo "${EXPECT[$i]}"; return; }; break; fi
	i=$((i+1)); done; hmd5 "$SRC/$1"; }

# Units: normally one (IMAGE_ROOT -> DEST). IMAGE_ROOT='*' installs each
# top-level folder of the image as /Applications-style sibling under DEST.
UNITS=()
if [ "$IMAGE_ROOT" = '*' ]; then
	for d in "$MNT"/*; do
		[ -d "$d" ] && [ ! -L "$d" ] && UNITS[${#UNITS[@]}]="$(basename "$d")"
	done
	[ ${#UNITS[@]} -gt 0 ] || die "image has no top-level folders to install" 1
else
	[ -d "$MNT/$IMAGE_ROOT" ] || die "image has no $IMAGE_ROOT" 1
	UNITS[0]=.
fi

# Staging must be on the same volume as the install, so the final step is a
# rename. ~/oldmac normally is; if not, stage hidden beside the install.
vol() { df "$1" 2>/dev/null | awk 'NR==2{print $1}'; }
mkdir -p "$DEST" || die "cannot create $DEST"
[ "$(vol "$ROOT")" = "$(vol "$DEST")" ] || { STAGE="$(dirname "$DEST")/.$PORT.stage.$$"; OLD="$(dirname "$DEST")/.$PORT.old.$$"; }
rm -rf "$STAGE" "$OLD"; mkdir -p "$STAGE" "$OLD" || die "cannot stage"

for u in "${UNITS[@]}"; do
	if [ "$u" = . ]; then SRC="$MNT/$IMAGE_ROOT"; UD="$DEST"; else SRC="$MNT/$u"; UD="$DEST/$u"; fi
	un="$u"; [ "$u" = . ] && un=_main      # a real directory name for the one-unit case
	ST="$STAGE/$un"; OU="$OLD/$un"; mkdir -p "$ST" "$OU" "$UD"

	# What this unit owns: OWNED, with '*' meaning every top-level entry.
	NAMES=()
	for p in "${OWNED[@]}"; do
		if [ "$p" = '*' ]; then
			for e in "$SRC"/* "$SRC"/.[!.]*; do [ -e "$e" ] && NAMES[${#NAMES[@]}]="$(basename "$e")"; done
		else NAMES[${#NAMES[@]}]="$p"
		fi
	done

	for p in "${NAMES[@]}"; do
		opt=no; case "$p" in *\?) opt=yes; p="${p%\?}" ;; esac
		if [ -e "$SRC/$p" ]; then
			mkdir -p "$(dirname "$ST/$p")"; ditto "$SRC/$p" "$ST/$p" || die "copy of $p failed"
		elif [ $opt = no ]; then
			die "the image lacks $p (listed in OWNED)"
		fi
	done

	# Byte-for-byte check of what will run; re-copy up to 3 times (old disks
	# and RAM do flip bytes: quake2/quake3 retry loops).
	for v in ${VERIFY[@]+"${VERIFY[@]}"}; do
		[ -e "$SRC/$v" ] || continue
		k=1
		while [ "$(hmd5 "$ST/$v")" != "$(want "$v")" ]; do
			[ $k -ge 4 ] && die "$v still differs from the image after $k copies" 7
			top="${v%%/*}"; rm -rf "$ST/$top"; ditto "$SRC/$top" "$ST/$top"; k=$((k+1))
		done
	done

	# Hooks see HOST (quake2 merges cfg lines on the workstation only), SRC, DEST.
	if [ -n "$POST_STAGE" ]; then ( cd "$ST" && SRC="$SRC" DEST="$UD" eval "$POST_STAGE" ) || die "post_stage hook failed"; fi

	# An empty DATA_DIR is seeded from the first FIRST_SEED (relative to ~) that
	# exists. Before the swap: an OWNED file may live inside DATA_DIR
	# (quake2's baseq2/game.so), and after the swap the dir is never empty.
	if [ -n "$DATA_DIR" ] && [ -z "$(ls -A "$UD/$DATA_DIR" 2>/dev/null)" ]; then
		for fs in ${FIRST_SEED[@]+"${FIRST_SEED[@]}"}; do
			[ -d "$HOME/$fs" ] || continue
			mkdir -p "$UD/$DATA_DIR"; ditto "$HOME/$fs" "$UD/$DATA_DIR" && say "seeded $DATA_DIR from ~/$fs"; break
		done
	fi

	# Swap: old OWNED paths aside (deleted below), staged ones into place.
	for p in "${NAMES[@]}"; do
		p="${p%\?}"
		if [ -e "$UD/$p" ] || [ -L "$UD/$p" ]; then mkdir -p "$(dirname "$OU/$p")"; mv "$UD/$p" "$OU/$p"; fi
		if [ -e "$ST/$p" ]; then mkdir -p "$(dirname "$UD/$p")"; mv "$ST/$p" "$UD/$p"; fi
	done

	bad=
	for v in ${VERIFY[@]+"${VERIFY[@]}"}; do
		[ -e "$SRC/$v" ] || continue
		[ "$(hmd5 "$UD/$v")" = "$(want "$v")" ] || bad="$v"
	done
	rm -rf "$OU"
	[ -z "$bad" ] || die "installed $bad does not match the image. Fix forward: redeploy (no rollback is kept)" 7

	for r in ${REMOVE[@]+"${REMOVE[@]}"}; do
		case "$r" in /*|*..*|'') continue ;; esac
		for f in "$UD"/$r; do [ -e "$f" ] && rm -rf "$f" && say "removed legacy $r"; done
	done
	for p in "${NAMES[@]}"; do
		p="${p%\?}"; [ -e "$UD/$p" ] || continue
		find "$UD/$p" -name .DS_Store -exec rm -f {} \; 2>/dev/null
		command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$UD/$p" 2>/dev/null
		case "$p" in *.app)
			touch "$UD/$p"   # with lsregister below: Panther otherwise keeps the generic icon
			for ls in /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
			          /System/Library/Frameworks/ApplicationServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; do
				[ -x "$ls" ] && { "$ls" -f "$UD/$p" >/dev/null 2>&1; break; }
			done ;;
		esac
	done
	if [ -n "$POST_INSTALL" ]; then ( cd "$UD" && DEST="$UD" eval "$POST_INSTALL" ) || die "post_install hook failed"; fi
	say "installed $UD"
done

rm -f "$ROOT/incoming/$DMG_BASE"; [ "$PRESTAGE" = 1 ] && rm -rf "$ROOT/prestage"
rm -rf "$ROOT/rollback"   # left by an earlier version of this script
say "verified; the replaced files are deleted (no rollback is kept)"
REMOTE
} | run_host
rc=$?
[ $rc -eq 0 ] && say "done ($MODE)" || echo "[deploy-dmg $HOST] FAILED ($MODE, rc=$rc)" >&2
exit $rc
