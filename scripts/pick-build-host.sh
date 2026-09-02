#!/usr/bin/env bash
# pick-build-host.sh - choose a free Intel cross-build host, and (optionally)
# claim it so nobody else grabs it mid-build.
#
# ============================================================================
# CANONICAL COPY. This file lives in old-mac-build-host, which owns the minis,
# and is distributed to the four game-port repos by scripts/sync-shared-scripts.sh.
# Edit it HERE and re-run that script; do not edit the copies.
#
# Why here and not in a game repo: every consumer is a peer (four ports plus this
# repo's own provisioning), so no port owns it. More practically, this is the
# repo you clone FIRST onto a fresh workstation during a recovery - the lock has
# to work before any game repo exists.
# ============================================================================
#
# WHY: there are now TWO interchangeable Intel Lion cross-build minis
# (mini-intel, mini-intel2 - same Macmini2,1 / 10.7.5 / same toolchain), and
# several agents/repos may want one at once. Every slice of every project
# cross-compiles on an Intel box, so the mini is the contended resource.
#
# WHY THE LOCK LIVES ON THE HOST, not in the repo:
#   The per-repo `flock $REPO_ROOT/build/.build.lock` only serialises builds
#   started from THE SAME checkout. It cannot see a build that old-mac-quake2
#   (or another Claude, or another workstation) is running on the same mini.
#   A lock directory on the mini itself is visible to everyone who can ssh in,
#   so it serialises across repos, agents and orchestrators. Keep BOTH: flock
#   still guards same-repo races, this guards cross-repo ones.
#
# usage:
#   scripts/pick-build-host.sh                  # print a free host, else exit 1
#   scripts/pick-build-host.sh --status         # table of every candidate
#   scripts/pick-build-host.sh --acquire LABEL  # pick + claim any free one
#   scripts/pick-build-host.sh --acquire-host HOST LABEL   # claim THAT one
#   scripts/pick-build-host.sh --release HOST   # drop our claim
#   scripts/pick-build-host.sh --release-all    # drop our claims everywhere
#
# env:
#   BUILD_HOSTS             candidate list (default "mini-intel mini-intel2")
#   BUILD_LOCK_WAIT         seconds to wait for a free host on --acquire (default 0)
#   BUILD_LOCK_STALE_SECS   age past which an idle lock is reclaimable (default 10800 = 3h)
#
# A host counts as BUSY if it holds a fresh lock, OR if compiler processes are
# running on it (catches builds started by hand, outside this mechanism).
# A lock is STALE - and reclaimed - only if it is old AND nothing is compiling,
# so a killed orchestrator can't wedge a mini forever.

set -uo pipefail

LOCK=/tmp/.retro-build-lock
BUILD_HOSTS="${BUILD_HOSTS:-mini-intel mini-intel2}"
STALE_SECS="${BUILD_LOCK_STALE_SECS:-10800}"
WAIT_SECS="${BUILD_LOCK_WAIT:-0}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)

REPO_NAME="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
ME="${USER:-unknown}@$(hostname -s 2>/dev/null || echo host):${REPO_NAME}"

# ME identifies a REPO, not a claimant. Two sessions in the same repo on this
# workstation produce a byte-identical ME, so release could not tell them apart.
# Issue #7, and it matters here as much as in the bench picker because both
# front-ends share ONE lock directory on the target: a loose release here can
# drop a claim the bench picker made.
#
# A claim carries a nonce, written as claim=... and required back at release.
# Unlike the bench picker there is no --run here, so every caller acquires in one
# process and releases from a trap in another; see build-fat.sh and build.sh in
# quake2, quake3 and quakespasm, and quake3 build-gamedylibs.sh. A pid would not
# survive that, so the nonce is opt-in: export BENCH_LOCK_CLAIM around the pair
# to get a strict release. Without it this falls back to the ME match, as before.
#
# No line numbers on purpose: this file ships byte-identical into four ports and
# their line numbers move without it changing.
CLAIM="${BENCH_LOCK_CLAIM:-}"

# Probe one host. Prints: "<age> <nprocs> <owner...>"  (age -1 = unlocked)
# Non-zero exit means unreachable.
probe() {
	ssh "${SSH_OPTS[@]}" "$1" '
		L=/tmp/.retro-build-lock
		if [ -d "$L" ]; then
			now=`date +%s`
			m=`stat -f %m "$L" 2>/dev/null || echo $now`
			age=`expr $now - $m`
			owner=`cat "$L/owner" 2>/dev/null | tr "\n" " "`
		else
			age=-1; owner=""
		fi
		# Compiler activity: waf, the legacy PPC drivers, cc1/clang, make, and the
		# newer drivers installed under ~/local by build-modern-tools.sh (gmake,
		# ninja) - without those two, a build driven by either would be INVISIBLE
		# here and another agent would happily claim a busy mini.
		# The leading (^|[ /]) plus `g?` matches "make" and "gmake" while still
		# excluding "cmake"/"qmake" (the character before "make" there is "c"/"q",
		# which g? cannot absorb). cmake stays excluded deliberately: it is a
		# short configure step, and the build it drives shows up as make or ninja.
		# makewhatis starts a line so it needs an explicit exclusion. Our own probe
		# line is dropped because it always contains "grep".
		n=`ps ax -o command= 2>/dev/null \
			| grep -E "(^|[ /])(g?make|waf|cc1|cc1plus|clang|collect2|ninja)|gcc-4\.0|g\+\+-4\.0|powerpc-apple-darwin10-" \
			| grep -vE "grep|makewhatis" | wc -l | tr -d " "`
		os=`sw_vers -productVersion 2>/dev/null || echo unknown`
		echo "$age $n $os $owner"
	' 2>/dev/null
}

# Expected booted OS per host, major.minor. Any host NOT listed here defaults to
# 10.7 - the interchangeable Lion pool's own OS, unchanged from before this
# function existed. That default is what already refuses mini-sl (10.6) by name
# (see classify() below); listing a host here only exists to give it a DIFFERENT
# expectation, same shape as pick-bench-host.sh's own expect_os(). build-host#48:
# imac-2019 is a real, verified cross-build host but is not a Lion box - it runs
# modern macOS and cross-compiles instead of building natively, so it needs its
# own entry, not folding into (or silently failing) the 10.7 default.
expect_os() {
	case "$1" in
		imac-2019|imac|sequoia-build) echo 15.7 ;;
		*)                            echo 10.7 ;;
	esac
}

# free | stale (reclaimable) | busy | unknown | wrong-os, given host+age+procs+os.
# Guard the numeric tests: a truncated/garbled probe (flaky ssh) must not blow up
# with "unary operator expected" NOR be silently read as free - treat it as
# unknown, and callers refuse to build on anything that is not free/stale.
#
# wrong-os exists because of mini-sl, the 10.6 box added 2026-08-04. This picker
# treats its DEFAULT-pool candidates as INTERCHANGEABLE, and a 10.6 host cannot
# build the Lion-targeted slices at all - no libc++, and a C++98-only compiler.
# The docs have always said "never add it to BUILD_HOSTS", but nothing enforced
# that, and an unenforced invariant is one typo away from a confusing mid-build
# failure or, worse, a silently wrong binary. Now it is refused by name, via
# expect_os() above rather than a hardcoded literal, so a genuinely different
# kind of host (imac-2019) can be checked against its OWN expected OS instead of
# being refused by the Lion-only assumption or, worse, having the check silently
# skipped for it.
classify() {
	local host="$1" age="$2" procs="$3" os="${4:-}" want
	want="$(expect_os "$host")"
	case "$os" in "$want"|"$want".*|'') : ;; *) echo wrong-os; return ;; esac
	case "$age"   in ''|*[!0-9-]*) echo unknown; return ;; esac
	case "$procs" in ''|*[!0-9]*)  echo unknown; return ;; esac
	if [ "$age" -lt 0 ]; then
		[ "$procs" -gt 0 ] && echo busy || echo free
	elif [ "$age" -gt "$STALE_SECS" ] && [ "$procs" -eq 0 ]; then
		echo stale
	else
		echo busy
	fi
}

# Only a free or stale host may be taken.
usable() { [ "$1" = free ] || [ "$1" = stale ]; }

cmd_status() {
	printf '%-14s %-12s %-8s %-8s %-6s %s\n' HOST STATE OS LOCK-AGE PROCS OWNER
	for h in $BUILD_HOSTS; do
		local out age procs os owner state
		if ! out="$(probe "$h")" || [ -z "$out" ]; then
			printf '%-14s %-12s %-8s %-8s %-6s %s\n' "$h" unreachable - - - -
			continue
		fi
		age="$(echo "$out" | awk '{print $1}')"
		procs="$(echo "$out" | awk '{print $2}')"
		os="$(echo "$out" | awk '{print $3}')"
		owner="$(echo "$out" | cut -d' ' -f4-)"
		state="$(classify "$h" "$age" "$procs" "$os")"
		case "$age" in ''|*[!0-9-]*) age=- ;; *) [ "$age" -lt 0 ] && age=- ;; esac
		printf '%-14s %-12s %-8s %-8s %-6s %s\n' "$h" "$state" "${os:--}" "$age" "$procs" "${owner:--}"
	done
}

# Try to claim $1. Returns 0 on success.
try_acquire() {
	local h="$1" label="$2" out age procs os state
	out="$(probe "$h")" || return 1
	[ -z "$out" ] && return 1
	age="$(echo "$out" | awk '{print $1}')"
	procs="$(echo "$out" | awk '{print $2}')"
	os="$(echo "$out" | awk '{print $3}')"
	state="$(classify "$h" "$age" "$procs" "$os")"
	usable "$state" || return 1
	# Only stamp claim= when there is a real nonce; an empty one would read as
	# "this lock has a nonce" at release and defeat the old-format fallback.
	CLAIM_TAG=""
	[ -n "$CLAIM" ] && CLAIM_TAG=" claim=$CLAIM"
	# Reclaim a stale lock first, then take it atomically via mkdir. The reclaim
	# itself goes through mv: only one claimant's mv of the stale dir succeeds,
	# so two orchestrators retrying the same stale lock cannot both pass their
	# age check, rm the other's fresh mkdir, and both build. stat-age-rm as three
	# separate commands had exactly that interleaving.
	ssh "${SSH_OPTS[@]}" "$h" "
		L=$LOCK
		if [ -d \"\$L\" ]; then
			now=\`date +%s\`; m=\`stat -f %m \"\$L\" 2>/dev/null || echo \$now\`
			if [ \`expr \$now - \$m\` -gt $STALE_SECS ]; then
				mv \"\$L\" \"\$L.reap.\$\$\" 2>/dev/null && rm -rf \"\$L.reap.\$\$\"
			fi
		fi
		mkdir \"\$L\" 2>/dev/null || exit 1
		echo '$ME$CLAIM_TAG $label' > \"\$L/owner\" 2>/dev/null
		date >> \"\$L/owner\" 2>/dev/null
		exit 0
	" >/dev/null 2>&1
}

cmd_acquire() {
	[ "${BENCH_NO_LOCK:-0}" = 1 ] && \
		echo "pick-build-host: BENCH_NO_LOCK is set but the build lock is never bypassed here." >&2

	local label="${1:-build}" deadline=$(( $(date +%s) + WAIT_SECS ))
	while :; do
		for h in $BUILD_HOSTS; do
			if try_acquire "$h" "$label"; then echo "$h"; return 0; fi
		done
		[ "$(date +%s)" -ge "$deadline" ] && break
		sleep 10
	done
	echo "pick-build-host: no free Intel build host in '$BUILD_HOSTS'" >&2
	echo "  (see: scripts/pick-build-host.sh --status)" >&2
	return 1
}

# Release our claim. Refuses to drop someone else's lock unless FORCE=1, so a
# stray --release can't yank a mini out from under another repo's running build.
# This picker has no --run, so there is nothing here that could safely bypass the
# lock: every caller acquires and holds. BENCH_NO_LOCK is therefore not honoured,
# and saying so beats ignoring it, since somebody set it expecting an effect.
# Issue #11.
cmd_release() {
	local h="$1"
	local strict=""
	[ -n "$CLAIM" ] && strict="claim=$CLAIM"
	# Say so when falling back to identity. Every split acquire/release caller in
	# the fleet lands here, and without this the release looks clean while being
	# the exact case issue #7 is about: ME is user@host:repo, two sessions in one
	# repo share it, and either can drop the other's lock. The bench picker has
	# said this since #7; this one did not, which is why the gap read as absent.
	if [ -z "$strict" ] && [ "${FORCE:-0}" != 1 ]; then
		echo "pick-build-host: releasing $h on identity alone; this cannot tell two" >&2
		echo "  sessions in $REPO_NAME apart. Export BENCH_LOCK_CLAIM around the" >&2
		echo "  acquire and the release to get a strict one." >&2
	fi
	ssh "${SSH_OPTS[@]}" "$h" "
		O=\"$LOCK/owner\"
		if [ -d \"$LOCK\" ]; then
			ok=0
			[ -n '$strict' ] && grep -q '$strict' \"\$O\" 2>/dev/null && ok=1
			# A lock written before nonces existed carries no claim= at all, so
			# fall back to identity for those. Drop once no pre-#7 picker is in
			# service.
			if [ \$ok -eq 0 ] && ! grep -q 'claim=' \"\$O\" 2>/dev/null; then
				grep -q '$ME' \"\$O\" 2>/dev/null && ok=1
			fi
			[ \"${FORCE:-0}\" = 1 ] && ok=1
			if [ \$ok -eq 1 ]; then
				rm -rf \"$LOCK\"; echo released
			else
				echo 'not ours; leaving it' >&2; exit 1
			fi
		else
			echo 'no lock held'
		fi
	" 2>&1
}

case "${1:---pick}" in
	--status)      cmd_status ;;
	--acquire)     cmd_acquire "${2:-build}" ;;
	# Claim one NAMED host rather than whichever is free. Needed whenever the work
	# is host-specific rather than interchangeable - provisioning a particular
	# mini, or reproducing a fault on the box that showed it. Without this the
	# only route was to override the candidate list (BUILD_HOSTS=<host> --acquire),
	# which works but reads like a hack and hides the intent.
	--acquire-host)
		h="${2:?usage: --acquire-host HOST [LABEL]}"
		BUILD_HOSTS="$h" cmd_acquire "${3:-build}" ;;
	--release)     cmd_release "${2:?usage: --release HOST}" ;;
	--release-all)
		# Walks every candidate applying the same test. On the identity-only path
		# that is one command that can drop a sibling session's claims, including
		# claims the BENCH picker made, since both share one lock directory.
		# Nothing in any repo calls this from code.
		if [ -z "$CLAIM" ] && [ "${FORCE:-0}" != 1 ]; then
			echo "pick-build-host: --release-all cannot tell two sessions in $REPO_NAME apart." >&2
			echo "  Use FORCE=1 --release-all to override, or BENCH_LOCK_CLAIM to scope it." >&2
			exit 2
		fi
		for h in $BUILD_HOSTS; do echo "$h: $(cmd_release "$h")"; done ;;
	--pick)
		for h in $BUILD_HOSTS; do
			out="$(probe "$h")" || continue
			[ -z "$out" ] && continue
			age="$(echo "$out" | awk '{print $1}')"
			procs="$(echo "$out" | awk '{print $2}')"
			os="$(echo "$out" | awk '{print $3}')"
			# os included: classify with it absent treats every OS as fine, so
			# bare --pick was the one path that could hand out a wrong-OS host.
			usable "$(classify "$h" "$age" "$procs" "$os")" || continue
			echo "$h"; exit 0
		done
		echo "pick-build-host: no free Intel build host in '$BUILD_HOSTS'" >&2
		exit 1 ;;
	-h|--help) sed -n '2,40p' "$0" ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
