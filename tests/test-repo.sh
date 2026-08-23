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
		if grep -qE 'mkdir -p "\$DEST/baseq2"|"\$STAGE/" "\$HOST:Desktop/quake2/"' "$f"; then
			if ! grep -qE 'rm -f .*baseq2/autoexec\.cfg' "$f"; then
				hits="$hits $f"
			fi
		fi
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

echo
[ "$FAILED" = 0 ] && echo "all repo invariants hold" || echo "repo invariants FAILED"
exit "$FAILED"
