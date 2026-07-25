#!/usr/bin/env bash
# pick-build-host.sh — choose a free Intel cross-build host, and (optionally)
# claim it so nobody else grabs it mid-build.
#
# WHY: there are now TWO interchangeable Intel Lion cross-build minis
# (mini-intel, mini-intel2 — same Macmini2,1 / 10.7.5 / same toolchain), and
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
#   scripts/pick-build-host.sh --acquire LABEL  # pick + claim, print the host
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
# A lock is STALE — and reclaimed — only if it is old AND nothing is compiling,
# so a killed orchestrator can't wedge a mini forever.

set -uo pipefail

LOCK=/tmp/.retro-build-lock
BUILD_HOSTS="${BUILD_HOSTS:-mini-intel mini-intel2}"
STALE_SECS="${BUILD_LOCK_STALE_SECS:-10800}"
WAIT_SECS="${BUILD_LOCK_WAIT:-0}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no)

REPO_NAME="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
ME="${USER:-unknown}@$(hostname -s 2>/dev/null || echo host):${REPO_NAME}"

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
		# Compiler activity: waf, the legacy PPC drivers, cc1/clang, make.
		# The leading (^|[ /]) stops "cmake"/"qmake" matching "make"; makewhatis
		# starts a line so it needs an explicit exclusion. Our own probe line is
		# dropped because it always contains "grep".
		n=`ps ax -o command= 2>/dev/null \
			| grep -E "(^|[ /])(make|waf|cc1|cc1plus|clang|collect2)|gcc-4\.0|g\+\+-4\.0|powerpc-apple-darwin10-" \
			| grep -vE "grep|makewhatis" | wc -l | tr -d " "`
		echo "$age $n $owner"
	' 2>/dev/null
}

# free | stale (reclaimable) | busy | unknown, given age+procs.
# Guard the numeric tests: a truncated/garbled probe (flaky ssh) must not blow up
# with "unary operator expected" NOR be silently read as free — treat it as
# unknown, and callers refuse to build on anything that is not free/stale.
classify() {
	local age="$1" procs="$2"
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
	printf '%-14s %-12s %-8s %-6s %s\n' HOST STATE LOCK-AGE PROCS OWNER
	for h in $BUILD_HOSTS; do
		local out age procs owner state
		if ! out="$(probe "$h")" || [ -z "$out" ]; then
			printf '%-14s %-12s %-8s %-6s %s\n' "$h" unreachable - - -
			continue
		fi
		age="$(echo "$out" | awk '{print $1}')"
		procs="$(echo "$out" | awk '{print $2}')"
		owner="$(echo "$out" | cut -d' ' -f3-)"
		state="$(classify "$age" "$procs")"
		[ "$age" -lt 0 ] && age=-
		printf '%-14s %-12s %-8s %-6s %s\n' "$h" "$state" "$age" "$procs" "${owner:--}"
	done
}

# Try to claim $1. Returns 0 on success.
try_acquire() {
	local h="$1" label="$2" out age procs state
	out="$(probe "$h")" || return 1
	[ -z "$out" ] && return 1
	age="$(echo "$out" | awk '{print $1}')"
	procs="$(echo "$out" | awk '{print $2}')"
	state="$(classify "$age" "$procs")"
	usable "$state" || return 1
	# Reclaim a stale lock first, then take it atomically via mkdir.
	ssh "${SSH_OPTS[@]}" "$h" "
		L=$LOCK
		if [ -d \"\$L\" ]; then
			now=\`date +%s\`; m=\`stat -f %m \"\$L\" 2>/dev/null || echo \$now\`
			if [ \`expr \$now - \$m\` -gt $STALE_SECS ]; then rm -rf \"\$L\"; fi
		fi
		mkdir \"\$L\" 2>/dev/null || exit 1
		echo '$ME $label' > \"\$L/owner\" 2>/dev/null
		date >> \"\$L/owner\" 2>/dev/null
		exit 0
	" >/dev/null 2>&1
}

cmd_acquire() {
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
cmd_release() {
	local h="$1"
	ssh "${SSH_OPTS[@]}" "$h" "
		if [ -d \"$LOCK\" ]; then
			if grep -q '$ME' \"$LOCK/owner\" 2>/dev/null || [ \"${FORCE:-0}\" = 1 ]; then
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
	--release)     cmd_release "${2:?usage: --release HOST}" ;;
	--release-all) for h in $BUILD_HOSTS; do echo "$h: $(cmd_release "$h")"; done ;;
	--pick)
		for h in $BUILD_HOSTS; do
			out="$(probe "$h")" || continue
			[ -z "$out" ] && continue
			age="$(echo "$out" | awk '{print $1}')"
			procs="$(echo "$out" | awk '{print $2}')"
			usable "$(classify "$age" "$procs")" || continue
			echo "$h"; exit 0
		done
		echo "pick-build-host: no free Intel build host in '$BUILD_HOSTS'" >&2
		exit 1 ;;
	-h|--help) sed -n '2,40p' "$0" ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
