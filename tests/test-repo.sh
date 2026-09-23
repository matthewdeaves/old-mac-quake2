#!/usr/bin/env bash
# Repo invariants. Runs on any Linux or macOS box, needs no fleet hardware, no
# toolchain and no network. CI runs it on ubuntu-latest; run it by hand the same
# way: tests/test-repo.sh
#
# These are not style checks. Each one encodes a bug this repo actually shipped,
# so a failure here means that bug is back, not that someone wrote it oddly.
#
# EVERY DETECTOR SELF-TESTS BEFORE IT IS TRUSTED. On 2026-08-22 three separate
# checks in one session reported a clean pass while unable to read their input:
# a grep over an unreadable directory returned "0 matches" and read as success.
# So each detector is first run against a known-BAD fixture, where it must fire,
# and a known-GOOD one, where it must not. If a detector cannot catch the bug it
# exists for, this script fails before it says anything about the repo.
# See MISTAKES.md, "Testing build scripts".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
pass () { printf '  ok    %s\n' "$1"; }
fail () { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# --- detectors -------------------------------------------------------------
# Each prints the offending files and returns 0 when it FINDS a problem.

# Issue #20. scripts/source-stamp.sh is canonical in old-mac-build-host and takes
# <dir> <excludes>; it returns 2 with one argument. Four call sites here passed
# one, so a sync of the shared file would have broken every build at once. This
# is build-host's own sync-hold regex: function, one quoted word, closing paren.
detect_one_arg_compute () {
	grep -rlE 'source_stamp_compute[[:space:]]+"[^"]*"[[:space:]]*\)' "$1" 2>/dev/null
}

# Issue #19. The bench-lock re-exec guard tested whether RETRO_BENCH_LOCK was
# SET rather than whether it named the machine being targeted, so a step
# claiming a second machine silently skipped its claim. The emptiness test is
# the bug; any [ -z ] on that variable is a regression.
detect_emptiness_lock_guard () {
	grep -rlE '\[[[:space:]]+-z[[:space:]]+"\$\{RETRO_BENCH_LOCK:?-?\}"' "$1" 2>/dev/null
}

# Issue #28. deploy.sh removed a stale ~/Desktop/quake2/baseq2/autoexec.cfg but
# deploy-dmg.sh did not, so the DMG path -- the one releases actually go out on
# -- could leave an orphan behind. FS_ExecAutoexec (yquake2 filesystem.c:1569)
# reads $fs_basedir/baseq2/autoexec.cfg and basedir is `.` here, so that file is
# queued AFTER the bundle layers finish in Com_Init and overrides the shipped
# per-machine overlay. The machine then runs something other than the product,
# and any bench taken on it prices a config the user does not have. Nothing
# errors; it is invisible until someone looks. Any script that installs into the
# deploy tree must remove it.
detect_install_without_cfg_cleanup () {
	local f hits=""
	for f in "$1"/*.sh; do
		[ -f "$f" ] || continue
		if grep -qE 'mkdir -p "\$DEST/baseq2"|"\$STAGE/" "\$HOST:Desktop/quake2/"|DEST="/Applications/Quake2"' "$f"; then
			if ! grep -qE 'rm -f .*baseq2/autoexec\.cfg' "$f"; then
				hits="$hits $f"
			fi
		fi
	done
	[ -n "$hits" ] || return 1
	printf '%s\n' $hits
}

# Issue #67. Build-host homes are shared by every port. A bare ~/quake2 mirror
# and /tmp staging scatter Q2 state across shared top-level locations instead
# of the one owned ~/oldmac/quake2 child. Catch the known old spellings in the
# build scripts before rsync --delete or cleanup can target them again.
detect_legacy_remote_build_layout () {
	grep -El 'REMOTE_PATH="quake2"|/Users/mini/quake2/|/tmp/q2-build-|/tmp/q2-fat-stage' "$1"/*.sh 2>/dev/null
}

# Issue #67. A fresh /Applications install must be staged on the same volume,
# preserve the old user-data tree by copying it, refuse an occupied destination,
# and become visible with one rename. Each missing property is the unsafe old
# shape, so print the installer if any is absent.
detect_unsafe_applications_install () {
	local f hits=""
	for f in "$1"/*.sh; do
		[ -f "$f" ] || continue
		grep -qE '(DEST|REMOTE_DEST)="/Applications/Quake2"' "$f" || continue
		grep -qE '(DEST_STAGE|REMOTE_STAGE)="/Applications/\.Quake2\.stage\.\$\$"' "$f" &&
		grep -qE '\[ ! -e .*\$DEST.*\].*\[ ! -L .*\$DEST.*\]' "$f" &&
		grep -qE 'ditto .*\$HOME/quake2-play/baseq2.*\$(DEST_STAGE|STAGE)/baseq2' "$f" &&
		grep -qE 'mv .*\$(DEST_STAGE|STAGE).*\$DEST' "$f" && continue
		hits="$hits $f"
	done
	[ -n "$hits" ] || return 1
	printf '%s\n' $hits
}

# --- self-test -------------------------------------------------------------
selftest () {
	local name="$1" fn="$2" bad="$3" good="$4"
	local tmp; tmp="$(mktemp -d)"
	mkdir -p "$tmp/bad" "$tmp/good"
	printf '%s\n' "$bad"  > "$tmp/bad/probe.sh"
	printf '%s\n' "$good" > "$tmp/good/probe.sh"
	if ! "$fn" "$tmp/bad" >/dev/null; then
		fail "$name: detector did NOT fire on known-bad input; the check is broken"
		rm -rf "$tmp"; return 1
	fi
	if "$fn" "$tmp/good" >/dev/null; then
		fail "$name: detector fired on known-good input; the check is broken"
		rm -rf "$tmp"; return 1
	fi
	pass "$name: detector fires on bad, silent on good"
	rm -rf "$tmp"
}

echo "self-test: prove each detector works before trusting it"
selftest "one-arg source_stamp_compute" detect_one_arg_compute \
	'X="$(source_stamp_compute "$REPO_ROOT")"' \
	'X="$(source_stamp_compute "$REPO_ROOT" "$SOURCE_STAMP_EXCLUDES")"'
selftest "emptiness lock guard" detect_emptiness_lock_guard \
	'if [ -z "${RETRO_BENCH_LOCK:-}" ] && [ -x "$_PICK" ]; then' \
	'if [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ] && [ -x "$_PICK" ]; then'
selftest "install without cfg cleanup" detect_install_without_cfg_cleanup \
	'mkdir -p "$DEST/baseq2"' \
	'mkdir -p "$DEST/baseq2"
rm -f "$DEST/baseq2/autoexec.cfg"'
selftest "legacy remote build layout" detect_legacy_remote_build_layout \
	'REMOTE_PATH="quake2"' \
	'REMOTE_PATH="oldmac/quake2"'
selftest "unsafe Applications install" detect_unsafe_applications_install \
	'DEST="/Applications/Quake2"' \
	'REMOTE_DEST="/Applications/Quake2"
REMOTE_STAGE="/Applications/.Quake2.stage.$$"
[ ! -e "$DEST" ] && [ ! -L "$DEST" ]
ditto "$HOME/quake2-play/baseq2" "$STAGE/baseq2"
mv "$STAGE" "$DEST"'

# --- the input must actually be there --------------------------------------
echo
echo "input"
SCRIPTS="$REPO_ROOT/scripts"
INPUT_OK=1
if [ ! -d "$SCRIPTS" ] || [ ! -r "$SCRIPTS" ]; then
	fail "scripts/ is missing or unreadable — a grep over it would report a false pass"
	INPUT_OK=0
else
	n_sh=$(find "$SCRIPTS" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
	if [ "$n_sh" -lt 10 ]; then
		fail "scripts/ has only $n_sh .sh files; expected at least 10, so the input is wrong"
		INPUT_OK=0
	else
		pass "scripts/ readable, $n_sh shell scripts"
	fi
fi

# --- the invariants --------------------------------------------------------
echo
echo "invariants"
# Do NOT report these as ok when there was nothing to read. A grep over a
# missing directory finds nothing and would otherwise print a pass, which is the
# exact false positive this script exists to avoid.
if [ "$INPUT_OK" = 0 ]; then
	echo "  ....  skipped, the input above is not usable"
elif hits=$(detect_one_arg_compute "$SCRIPTS"); then
	fail "source_stamp_compute called with one argument (issue #20):"
	printf '        %s\n' $hits
else
	pass "no one-argument source_stamp_compute; the shared file can be synced"
fi

if [ "$INPUT_OK" = 0 ]; then
	:
elif hits=$(detect_emptiness_lock_guard "$SCRIPTS"); then
	fail "bench-lock guard tests RETRO_BENCH_LOCK for emptiness (issue #19):"
	printf '        %s\n' $hits
else
	pass "every bench-lock guard compares against its target"
fi

if [ "$INPUT_OK" = 0 ]; then
	:
elif hits=$(detect_install_without_cfg_cleanup "$SCRIPTS"); then
	fail "installs into the deploy tree but leaves a stale baseq2/autoexec.cfg (issue #28):"
	printf '        %s\n' $hits
else
	pass "every deploy path clears a stale baseq2/autoexec.cfg"
fi

if [ "$INPUT_OK" = 0 ]; then
	:
elif hits=$(detect_legacy_remote_build_layout "$SCRIPTS"); then
	fail "legacy remote build path escapes ~/oldmac/quake2 (issue #67):"
	printf '        %s\n' $hits
else
	pass "remote build mirror, logs and fat stage stay under ~/oldmac/quake2"
fi

if [ "$INPUT_OK" = 0 ]; then
	:
elif hits=$(detect_unsafe_applications_install "$SCRIPTS"); then
	fail "unsafe /Applications/Quake2 installer shape (issue #67):"
	printf '        %s\n' $hits
else
	pass "/Applications/Quake2 installs are staged, collision-safe and preserve rollback data"
fi

if "$REPO_ROOT/tests/test-update-install.sh"; then
	pass "occupied-install updater preserves data and restores failed or selected rollbacks"
else
	fail "occupied-install updater fixture failed"
fi

# The Cocoa surface-setup callback also activates the app and marks the view
# dirty. Calling it for every window update stalls the M5 in WindowServer IPC.
detect_window_update_observer() {
	grep -Eq 'name:[[:space:]]*NSWindowDidUpdateNotification'
}
if ! printf '%s\n' 'name:NSWindowDidUpdateNotification' | detect_window_update_observer; then
	fail "window-update detector missed the bad fixture"
elif printf '%s\n' 'name:NSWindowDidBecomeKeyNotification' | detect_window_update_observer; then
	fail "window-update detector rejected the good fixture"
elif [ ! -s "$REPO_ROOT/yquake2/src/backends/sdl_osx/SDLMain.m" ]; then
	fail "missing Cocoa launcher source"
elif detect_window_update_observer < "$REPO_ROOT/yquake2/src/backends/sdl_osx/SDLMain.m"; then
	fail "Cocoa launcher subscribes surface setup to every window update"
else
	pass "Cocoa surface setup is not driven by recurring window updates"
fi

# Issue #79. Every hw.model overlay must declare the GPU it was measured on,
# or R_Init cannot verify it and drops that machine to the capability tier.
detect_undeclared_overlays () { # $1 = misc.c, $2 = bundle dir
	local cfg hits=""
	for cfg in $(grep -oE '"autoexec-[a-z0-9-]+" *\}' "$1" | grep -oE 'autoexec-[a-z0-9-]+' | sort -u); do
		grep -qE '^set q2_overlay_gpu "[a-z0-9 ]+"$' "$2/$cfg.cfg" 2>/dev/null || hits="$hits $cfg"
	done
	[ -n "$hits" ] || return 1
	printf '%s\n' $hits
}
ov_tmp="$(mktemp -d)"
printf '{ "PowerMac1,1", "autoexec-good" },\n{ "PowerMac3,1", "autoexec-bad" },\n' > "$ov_tmp/misc.c"
printf 'set q2_overlay_gpu "rage 128"\n' > "$ov_tmp/autoexec-good.cfg"
printf 'set gl_bloom 0\n' > "$ov_tmp/autoexec-bad.cfg"
if [ "$(detect_undeclared_overlays "$ov_tmp/misc.c" "$ov_tmp")" != autoexec-bad ]; then
	fail "overlay GPU detector did not isolate the undeclared fixture"
elif undeclared="$(detect_undeclared_overlays "$REPO_ROOT/yquake2/src/common/misc.c" "$REPO_ROOT/scripts/bundle")"; then
	fail "overlays without q2_overlay_gpu: $undeclared"
else
	pass "every hw.model overlay declares the GPU it was measured on"
fi
rm -rf "$ov_tmp"

# Issue #81. The build mirror's rsync --delete targets ~/oldmac/quake2, where a
# mini that is also an install target keeps its staged DMG and rollbacks.
keep_tmp="$(mktemp -d)"
mkdir -p "$keep_tmp/src/yquake2" "$keep_tmp/dst/rollbacks/Quake2.rollback-x" "$keep_tmp/dst/yquake2" "$keep_tmp/dst/mnt/install"
: > "$keep_tmp/src/yquake2/kept.c"
: > "$keep_tmp/dst/Quake2-OldMac-vX.dmg"
: > "$keep_tmp/dst/rollbacks/Quake2.rollback-x/quake2"
: > "$keep_tmp/dst/yquake2/stale.c"
: > "$keep_tmp/dst/mnt/install/README.txt"
if ! grep -q -- "REMOTE_KEEP_EXCLUDES=(--exclude=/rollbacks/ --exclude='/\*.dmg' --exclude=/mnt/)" "$REPO_ROOT/scripts/build.sh" ||
	! grep -q -- '"\${REMOTE_KEEP_EXCLUDES\[@\]}"' "$REPO_ROOT/scripts/build.sh"; then
	fail "build.sh source mirror does not protect staged DMGs and rollbacks"
elif ! rsync -a --delete --exclude=/rollbacks/ --exclude='/*.dmg' --exclude=/mnt/ "$keep_tmp/src/" "$keep_tmp/dst/"; then
	fail "rsync protect-rule fixture could not run"
elif [ ! -e "$keep_tmp/dst/Quake2-OldMac-vX.dmg" ] || [ ! -e "$keep_tmp/dst/rollbacks/Quake2.rollback-x/quake2" ] || [ ! -e "$keep_tmp/dst/mnt/install/README.txt" ]; then
	fail "rsync --delete removed a staged DMG, rollback or mounted image"
elif [ -e "$keep_tmp/dst/yquake2/stale.c" ] || [ ! -e "$keep_tmp/dst/yquake2/kept.c" ]; then
	fail "protect rules stopped the mirror deleting stale sources"
else
	pass "build mirror keeps staged DMGs, rollbacks and mounts, still deletes stale sources"
fi
rm -rf "$keep_tmp"

# Issue #85. Concurrent attaches of one image file race in hdiutil ("Resource
# busy"), so the local preflight must mount a private clone of the DMG.
if grep -q 'hdiutil attach -nobrowse -readonly -mountpoint "\$MOUNT" "\$PRIVATE_DMG"' "$REPO_ROOT/scripts/update-dmg.sh" &&
	! grep -q 'hdiutil attach -nobrowse -readonly -mountpoint "\$MOUNT" "\$DMG"' "$REPO_ROOT/scripts/update-dmg.sh"; then
	pass "update-dmg preflight mounts a private DMG clone"
else
	fail "update-dmg preflight attaches the shared dist/ DMG (parallel updates collide, #85)"
fi

echo
[ "$FAILED" = 0 ] && echo "all repo invariants hold" || echo "repo invariants FAILED"
exit "$FAILED"
