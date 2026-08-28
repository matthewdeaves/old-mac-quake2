#!/usr/bin/env bash
# pick-bench-host.sh - claim a BENCH/TEST Mac so two sessions cannot deploy to,
# bench on, or reboot the same machine at once.
#
# ============================================================================
# CANONICAL COPY. This file lives in old-mac-build-host, which owns the fleet,
# and is distributed to the four game-port repos by scripts/sync-shared-scripts.sh.
# Edit it HERE and re-run that script; do not edit the copies.
# ============================================================================
#
# WHY THIS EXISTS, and why it is not pick-build-host.sh
# ----------------------------------------------------
# pick-build-host.sh arbitrates the two Intel Lion minis, which are
# INTERCHANGEABLE: the caller wants "a" build host and does not care which.
# Bench machines are the opposite. The whole point of benching on quicksilver
# is that it is quicksilver. So there is no --pick and no candidate list to
# choose from: you name the host you want, and you either get it or you do not.
#
# Everything else that made the build lock work applies unchanged: the lock is a
# directory on the TARGET (/tmp/.retro-build-lock), so it is visible to every
# repo, agent and workstation that can ssh in, and a host counts as busy if it
# holds a fresh lock OR has real work running on it.
#
# THE LOCK PATH IS SHARED WITH pick-build-host.sh, DELIBERATELY.
#   mini-intel and mini-intel2 are in BOTH pools: they cross-compile every slice
#   AND they are deploy/bench targets. A second lock path would let a bench run
#   and a build proceed on the same 2-core 2 GB machine, which ruins the build
#   time and silently ruins the benchmark numbers, and neither side would see
#   the other. One lock, two front-ends.
#
# usage:
#   scripts/pick-bench-host.sh --status [HOST ...]   # table (default: whole fleet)
#   scripts/pick-bench-host.sh --acquire HOST LABEL  # claim it, or fail
#   scripts/pick-bench-host.sh --run HOST LABEL -- CMD ...   # claim, run, release
#   scripts/pick-bench-host.sh --release HOST        # drop our claim
#   scripts/pick-bench-host.sh --release-all         # drop our claims everywhere
#
# env:
#   BENCH_HOSTS             fleet list for --status (default: all known aliases)
#   BENCH_LOCK_WAIT         seconds to wait for the host on --acquire (default 0)
#   BENCH_LOCK_STALE_SECS   age past which an idle lock is reclaimable
#                           (default 5400 = 90m; a bench sweep is much shorter
#                           than a build, so this is half the build lock's 3h)
#   BENCH_SKIP_OS_CHECK=1   bypass the booted-OS check (see below; last resort)
#
# ---------------------------------------------------------------------------
# TWO THINGS MEASURED ON THIS FLEET THAT THE BUILD LOCK GETS AWAY WITH
# ---------------------------------------------------------------------------
#
# 1. THERE IS NO `stat` ON 10.3.9. Measured on yosemite 2026-08-22:
#      stat -f %m /tmp  ->  command not found
#    pick-build-host.sh reads a lock's age with `stat -f %m`, falling back to
#    `echo $now` on failure. That fallback yields age 0, i.e. "just created", so
#    a lock on the G3 would look FRESH forever and could never be reclaimed: one
#    killed session would wedge the machine permanently. It never bit because
#    that script only ever talks to Lion.
#    So we do not stat anything. mkdir writes `created` inside the lock holding
#    the epoch second, and age is now minus that. Works identically on 10.3
#    through macOS 26. A lock with no `created` file was made by
#    pick-build-host.sh, so we fall back to stat for it, and if that fails too
#    we treat the age as unknown and refuse to reclaim, which is the safe way to
#    be wrong.
#
# 2. StrictHostKeyChecking=no DEFEATS THE MULTI-BOOT GUARD.
#    The G3, the dual G5 and the quad G5 each serve several aliases on ONE IP
#    (yosemite/yosemite-tiger, g5-panther/g5-tiger/g5-desktop,
#    quad-tiger/quad-leopard). Only one partition is booted at a time. What
#    makes the wrong alias fail is the HOST KEY not matching, and nothing else.
#    Measured 2026-08-22, quad booted into Leopard:
#      ssh quad-tiger                        -> HOST IDENTIFICATION HAS CHANGED
#      ssh -o StrictHostKeyChecking=no quad-tiger -> connects, reports 10.5.8
#    pick-build-host.sh sets StrictHostKeyChecking=no. Copying that here would
#    make `--acquire quad-tiger` succeed against a Leopard-booted quad and hand
#    back a host that labels every benchmark row "tiger" while running Leopard.
#    We use accept-new instead: a first-time key is accepted so a new machine
#    still onboards without a prompt, a CHANGED key is refused.
#
#    accept-new only protects an alias whose key is already recorded, so we also
#    check the booted OS positively against EXPECT_OS below. Belt and braces,
#    because the cost of getting this wrong is a plausible-looking CSV row.
#
# 3. ONE HOST NEEDS NO SSH AT ALL: `workstation`, the arm64 Apple Silicon Mac
#    THIS SCRIPT ITSELF OFTEN RUNS ON. Every other host is a fleet Mac reached
#    over the network; this one is local, so ssh-to-self would need a working
#    sshd and a hostkey dance against a machine already trusted implicitly.
#    LOCAL_ALIASES below names it, and run_remote() dispatches to a plain `sh
#    -c` instead of ssh for a host in that set -- same lock directory, same
#    probe script, same classify()/stale rules, just no transport. Added
#    build-host#32: the workstation is also the fleet controller for up to
#    a dozen resident tmux sessions across the port repos, so the claim is
#    READ-ONLY against `ps ax` and never signals another process -- it can
#    refuse to run because something else looks busy, but it cannot be the
#    thing that disrupts a sibling session.
# ---------------------------------------------------------------------------

set -uo pipefail

LOCK=/tmp/.retro-build-lock
STALE_SECS="${BENCH_LOCK_STALE_SECS:-5400}"
WAIT_SECS="${BENCH_LOCK_WAIT:-0}"

# Every engine name this fleet ships, by every name it runs under. Shared
# between probe()'s busy-detection and cmd_release's lingering-game check
# (issue #38) so the two cannot drift apart -- a name missing here both
# undercounts "busy" AND lets that game survive a release unquit.
#
# Aleph One is the recurring case, twice in one day: first seen as
# `alephone-ppc-test` (a dev binary), then as `Classic Marathon` -- a
# per-game CFBundleExecutable name that its own packaging script sets, not a
# fixed binary name (alephone-fd, 2026-08-28). "Marathon" alone still matches
# it via the same word-boundary rule ($|[ /]) that already matches every
# other name here, since "Classic Marathon" ends in that word. A fixed list
# is fundamentally not future-proof against a name nobody has hit yet --
# noted here rather than solved: matching on the `.app` bundle path or a
# marker file would generalise better and is a fair follow-up if another
# name turns up, but is not built today.
GAME_PROC_REGEX='(^|[ /])(xash3d|xash3d\.bin|quake2|q2ded|quake3|ioquake3|ioq3ded|quakespasm|alephone|alephone-ppc-test|AlephOne|Marathon)($|[ /])'

# accept-new, never `no`. See note 2 above.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

# Every bench/test target. The two minis appear because they are deploy targets
# as well as build hosts; the shared lock path is what keeps those two roles
# from colliding. `workstation` is the arm64 Apple Silicon Mac -- see note 3
# above and LOCAL_ALIASES below: it is claimed and released the same way as
# every other host, just without ssh.
BENCH_HOSTS="${BENCH_HOSTS:-yosemite yosemite-tiger sawtooth quicksilver mini-g4 imac-g5 g5-panther g5-tiger g5-desktop quad-tiger quad-leopard mini-sl mini-intel mini-intel2 imac-2019 workstation}"

# Hosts reached by local exec instead of ssh: this machine talking to itself.
# Space-separated, matched as a whole word so "workstation" cannot accidentally
# prefix-match some future "workstation2".
LOCAL_ALIASES="${LOCAL_ALIASES:-workstation}"
is_local_host() {
	case " $LOCAL_ALIASES " in
		*" $1 "*) return 0 ;;
		*)        return 1 ;;
	esac
}

# Expected booted OS per alias, major.minor. An alias that is NOT in this table
# is accepted with no OS check, so adding a machine does not require editing
# this first. Sources: README fleet matrix, each port's bench.sh header, and
# sw_vers measured across the fleet 2026-08-22.
expect_os() {
	case "$1" in
		yosemite|g3-panther)             echo 10.3 ;;
		yosemite-tiger|g3-tiger)         echo 10.4 ;;
		sawtooth|g4-sawtooth)            echo 10.4 ;;
		quicksilver|g4-quicksilver)      echo 10.4 ;;
		mini-g4|g4-mini)                 echo 10.4 ;;
		imac-g5|g5-imac)                 echo 10.5 ;;
		g5-panther)                      echo 10.3 ;;
		g5-tiger)                        echo 10.4 ;;
		g5-desktop|g5-leopard)           echo 10.5 ;;
		quad-tiger|g5quad-tiger)         echo 10.4 ;;
		quad-leopard|g5quad-leopard)     echo 10.5 ;;
		mini-sl|snow-build1)             echo 10.6 ;;
		mini-intel|lion-build1)          echo 10.7 ;;
		mini-intel2|lion-build2)         echo 10.7 ;;
		imac-2019|imac|sequoia-build)    echo 15.7 ;;
		workstation)                     echo 26 ;;
		*)                               echo "" ;;
	esac
}

REPO_NAME="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
ME="${USER:-unknown}@$(hostname -s 2>/dev/null || echo host):${REPO_NAME}"

# ME identifies a REPO, not a claimant, and that is not enough to release safely.
# Two sessions in the same repo on this workstation produce a byte-identical ME,
# so cmd_release could not tell them apart and either could drop the other's
# lock with no error. Sessions here are restarted to control token spend, and a
# restarted session briefly coexists with its predecessor in the same repo,
# which is exactly that condition. Issue #7.
#
# So a claim also carries a nonce, written into the owner file as claim=... and
# required back at release.
#
# It cannot simply be $$. Every build script in the four ports acquires in one
# process and releases from a trap in ANOTHER:
#     BUILD_HOST="$(pick-build-host.sh --acquire "quake2 build-fat")"
#     trap '... --release "$BUILD_HOST"' EXIT
# That shape is in quake2 build-fat.sh and build.sh, quake3 build-fat.sh,
# build-gamedylibs.sh and build.sh, and quakespasm build-fat.sh and build.sh.
# Seven callers, four repos. A pid match would refuse every one of those
# releases, so the lock would be held until the 90 minute reclaim on every build
# in the fleet.
#
# Deliberately no line numbers for those files. This comment ships BYTE-IDENTICAL
# into all four ports, and their line numbers move without this file changing, so
# any number here rots silently and cannot be verified from the repo it lives in.
#
# Hence: --run generates a nonce and uses it for both halves, because it is one
# invocation and that is the case the trap-ordering bug actually bites. A caller
# that splits acquire from release opts in by exporting BENCH_LOCK_CLAIM, and
# without it falls back to the old ME match with a warning. Loose, but no worse
# than it was, and no build in the fleet has to change to keep working.
CLAIM="${BENCH_LOCK_CLAIM:-}"

new_claim() { echo "$$.$(date +%s).${RANDOM:-0}"; }

# Run a lock-manipulating shell fragment on $1: over ssh normally, or as a
# local `sh -c` for a host in LOCAL_ALIASES. $2 is the script; $3 (optional)
# says what to do with stderr -- "&1" merges it into stdout (cmd_release wants
# combined output back), a path captures it to a file (cmd_status wants the
# REASON a probe failed), empty leaves it on the caller's stderr. Same
# signature either way, so probe/try_acquire/cmd_release do not need to know
# which transport they got.
run_remote() {
	local h="$1" script="$2" errsink="${3:-}"
	if is_local_host "$h"; then
		case "$errsink" in
			"")   sh -c "$script" ;;
			"&1") sh -c "$script" 2>&1 ;;
			*)    sh -c "$script" 2>"$errsink" ;;
		esac
	else
		case "$errsink" in
			"")   ssh "${SSH_OPTS[@]}" "$h" "$script" ;;
			"&1") ssh "${SSH_OPTS[@]}" "$h" "$script" 2>&1 ;;
			*)    ssh "${SSH_OPTS[@]}" "$h" "$script" 2>"$errsink" ;;
		esac
	fi
}

# Probe one host. Prints: "<age> <nprocs> <os> <owner...>"  (age -1 = unlocked,
# age -2 = locked but age unknowable). Non-zero exit means unreachable.
#
# The process regex covers three kinds of work, because any of them means the
# machine is in use and must not be deployed over or rebooted:
#   the four game engines, benching or being played, by every name they run
#     under (Half-Life runs as xash3d.bin behind the xash3d launcher);
#   a deploy in flight (hdiutil attached, ditto copying a bundle);
#   a compile, since the two minis are build hosts too and pick-build-host.sh
#     may have started one.
# Our own probe line always contains "grep", so it is dropped.
probe() {
	# $2, optional: a file to receive ssh's stderr. Default /dev/null preserves
	# the old behaviour for try_acquire, which only cares whether it worked.
	# cmd_status passes a real file, because the REASON a probe failed is the
	# thing issue #14 is about: without it a timeout, an auth failure and a
	# powered-off machine are one indistinguishable word.
	local errsink="${2:-/dev/null}"
	run_remote "$1" '
		L=/tmp/.retro-build-lock
		if [ -d "$L" ]; then
			now=`date +%s`
			if [ -r "$L/created" ]; then
				m=`cat "$L/created" 2>/dev/null`
			else
				m=`stat -f %m "$L" 2>/dev/null`
			fi
			case "$m" in
				""|*[!0-9]*) age=-2 ;;
				*)           age=`expr $now - $m` ;;
			esac
			owner=`cat "$L/owner" 2>/dev/null | tr "\n" " "`
		else
			age=-1; owner=""
		fi
		n=`ps ax -o command= 2>/dev/null \
			| grep -E "'"$GAME_PROC_REGEX"'|(^|[ /])(hdiutil|ditto)($|[ /])|(^|[ /])(g?make|waf|cc1|cc1plus|clang|collect2|ninja)($|[ /])" \
			| grep -vE "grep|makewhatis|pick-build-host\.sh|pick-bench-host\.sh" | wc -l | tr -d " "`
		os=`sw_vers -productVersion 2>/dev/null || echo unknown`
		echo "$age $n $os $owner"
	' "$errsink"
}

# Why did a probe fail? Reads ssh's stderr and returns ONE word.
#
# Issue #14: --status printed `unreachable` for every failure, so a machine that
# was switched off on purpose, one too loaded to answer in 8s, and one we simply
# cannot authenticate to all read identically. On 2026-08-23 two sessions read a
# five-hour `unreachable` window and both concluded the wrong thing; the fleet
# had been shut down deliberately. The instrument could not express the answer.
#
# The distinction that matters most is refused/no-route versus timeout. A refused
# connection is an ANSWER -- something is there and declining -- and a timeout is
# the absence of one, which on this fleet usually means the machine is busy. Busy
# is exactly when writing to a machine does damage, and it used to present as
# nothing-here.
why_probe_failed() {
	local err="" f="$1"
	[ -r "$f" ] && err="$(cat "$f" 2>/dev/null)"
	case "$err" in
		*"Connection refused"*)                       echo refused ;;
		*"No route to host"*|*"Host is down"*|*"Network is unreachable"*) echo off ;;
		*"Connection timed out"*|*"Operation timed out"*|*"timed out"*)   echo timeout ;;
		*"Permission denied"*|*"Too many authentication failures"*|*"No supported authentication"*) echo auth ;;
		*"Could not resolve"*|*"Name or service not known"*|*"nodename nor servname"*) echo dns ;;
		*"Unable to negotiate"*|*"no matching"*)      echo crypto ;;
		*"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*) echo hostkey ;;
		"")                                           echo unreachable ;;
		*)                                            echo unreachable ;;
	esac
}

# free | stale | busy | unknown | wrong-os
#
# age -2 (locked, age unknowable) classifies as busy, never stale: refusing to
# reclaim a lock we cannot date is the safe way to be wrong. It costs a wait;
# the other way costs two sessions on one machine.
classify() {
	local age="$1" procs="$2" os="${3:-}" want="${4:-}"
	if [ -n "$want" ] && [ "${BENCH_SKIP_OS_CHECK:-0}" != 1 ]; then
		case "$os" in
			"$want"|"$want".*) : ;;
			*) echo wrong-os; return ;;
		esac
	fi
	case "$age"   in ''|*[!0-9-]*) echo unknown; return ;; esac
	case "$procs" in ''|*[!0-9]*)  echo unknown; return ;; esac
	if [ "$age" = -1 ]; then
		[ "$procs" -gt 0 ] && echo busy || echo free
	elif [ "$age" -lt 0 ]; then
		echo busy
	elif [ "$age" -gt "$STALE_SECS" ] && [ "$procs" -eq 0 ]; then
		echo stale
	else
		echo busy
	fi
}

usable() { [ "$1" = free ] || [ "$1" = stale ]; }

cmd_status() {
	local hosts="$*"
	[ -z "$hosts" ] && hosts="$BENCH_HOSTS"
	printf '%-16s %-12s %-8s %-8s %-9s %-6s %s\n' HOST STATE OS WANT LOCK-AGE PROCS OWNER
	local errf
	errf="$(mktemp "${TMPDIR:-/tmp}/pick-bench-probe.XXXXXX")" || errf=/dev/null
	for h in $hosts; do
		local out age procs os owner state want why
		want="$(expect_os "$h")"
		if ! out="$(probe "$h" "$errf")" || [ -z "$out" ]; then
			why="$(why_probe_failed "$errf")"
			# Retry ONLY a timeout. A refused connection, an auth failure and a
			# dead name are answers already, and re-asking costs another 8s per
			# host across 14 hosts to learn nothing. A timeout is the one case
			# where the machine may simply have been too busy to answer, which
			# is the case #14 measured: mini-intel answered 7 of 9 probes while
			# under a bench, and the two failures were consecutive.
			if [ "$why" = timeout ]; then
				if ! out="$(probe "$h" "$errf")" || [ -z "$out" ]; then
					why="$(why_probe_failed "$errf")"
					[ "$why" = unreachable ] && why=timeout
				fi
			fi
			if [ -z "${out:-}" ]; then
				[ "${BENCH_PROBE_VERBOSE:-0}" = 1 ] && \
					printf 'probe %s: %s\n' "$h" "$(tr '\n' ' ' < "$errf")" >&2
				printf '%-16s %-12s %-8s %-8s %-9s %-6s %s\n' "$h" "$why" - "${want:--}" - - -
				continue
			fi
		fi
		age="$(echo "$out" | awk '{print $1}')"
		procs="$(echo "$out" | awk '{print $2}')"
		os="$(echo "$out" | awk '{print $3}')"
		owner="$(echo "$out" | cut -d' ' -f4-)"
		state="$(classify "$age" "$procs" "$os" "$want")"
		case "$age" in ''|*[!0-9-]*) age=- ;; *) [ "$age" -lt 0 ] && age=- ;; esac
		printf '%-16s %-12s %-8s %-8s %-9s %-6s %s\n' \
			"$h" "$state" "${os:--}" "${want:--}" "$age" "$procs" "${owner:--}"
	done
	[ "$errf" = /dev/null ] || rm -f "$errf"
}

# Try to claim $1. Returns 0 on success.
try_acquire() {
	local h="$1" label="$2" out age procs os state want tag
	# Only stamp claim= when there is a real nonce. An empty claim= would read as
	# "this lock has a nonce" to cmd_release and defeat the old-format fallback.
	tag=""
	[ -n "$CLAIM" ] && tag=" claim=$CLAIM"
	want="$(expect_os "$h")"
	out="$(probe "$h")" || return 1
	[ -z "$out" ] && return 1
	age="$(echo "$out" | awk '{print $1}')"
	procs="$(echo "$out" | awk '{print $2}')"
	os="$(echo "$out" | awk '{print $3}')"
	state="$(classify "$age" "$procs" "$os" "$want")"
	if [ "$state" = wrong-os ]; then
		echo "pick-bench-host: $h is booted into $os, expected $want.*" >&2
		echo "  These aliases share one IP and one OS boots at a time. Either bless" >&2
		echo "  and reboot into the partition you want, or bench the booted one." >&2
		echo "  (BENCH_SKIP_OS_CHECK=1 overrides, and will mislabel your results.)" >&2
		return 2
	fi
	usable "$state" || return 1
	# Reclaim a stale lock via mv, so only one claimant's reclaim can succeed and
	# two retriers cannot both pass the age check and both proceed. Then mkdir,
	# which is the atomic part. `created` is written FIRST so a lock is never
	# visible without its timestamp.
	run_remote "$h" "
		L=$LOCK
		if [ -d \"\$L\" ]; then
			now=\`date +%s\`
			if [ -r \"\$L/created\" ]; then m=\`cat \"\$L/created\" 2>/dev/null\`
			else m=\`stat -f %m \"\$L\" 2>/dev/null\`; fi
			case \"\$m\" in
				''|*[!0-9]*) : ;;
				*) if [ \`expr \$now - \$m\` -gt $STALE_SECS ]; then
					mv \"\$L\" \"\$L.reap.\$\$\" 2>/dev/null && rm -rf \"\$L.reap.\$\$\"
				   fi ;;
			esac
		fi
		mkdir \"\$L\" 2>/dev/null || exit 1
		date +%s > \"\$L/created\" 2>/dev/null
		echo '$ME$tag $label (bench)' > \"\$L/owner\" 2>/dev/null
		date >> \"\$L/owner\" 2>/dev/null
		exit 0
	" >/dev/null 2>&1
}

cmd_acquire() {
	local h="${1:?usage: --acquire HOST [LABEL]}" label="${2:-bench}"
	# See cmd_run: the bypass is not honoured here, because a caller told
	# "acquired" while holding nothing would use a machine it does not own. Say so
	# rather than ignoring it silently, since somebody set it expecting an effect.
	[ "${BENCH_NO_LOCK:-0}" = 1 ] && \
		echo "pick-bench-host: BENCH_NO_LOCK is set but --acquire always claims; use --run to bypass." >&2
	local deadline=$(( $(date +%s) + WAIT_SECS )) rc
	while :; do
		try_acquire "$h" "$label"; rc=$?
		[ $rc -eq 0 ] && { echo "$h"; return 0; }
		# wrong-os is not something waiting will fix.
		[ $rc -eq 2 ] && return 1
		[ "$(date +%s)" -ge "$deadline" ] && break
		sleep 10
	done
	echo "pick-bench-host: $h is not available" >&2
	echo "  (see: scripts/pick-bench-host.sh --status $h)" >&2
	return 1
}

# Refuses to drop someone else's lock unless FORCE=1, so a stray --release
# cannot yank a machine out from under another repo's running bench.
cmd_release() {
	local h="$1"
	local strict=""
	[ -n "$CLAIM" ] && strict="claim=$CLAIM"
	if [ -z "$strict" ] && [ "${FORCE:-0}" != 1 ]; then
		echo "pick-bench-host: releasing $h on identity alone; this cannot tell two" >&2
		echo "  sessions in $REPO_NAME apart. Export BENCH_LOCK_CLAIM to release strictly." >&2
	fi
	run_remote "$h" "
		O=\"$LOCK/owner\"
		if [ -d \"$LOCK\" ]; then
			ok=0
			# Our own claim, by nonce. The only test that distinguishes two
			# sessions in one repo.
			[ -n '$strict' ] && grep -q '$strict' \"\$O\" 2>/dev/null && ok=1
			# A lock written before nonces existed carries no claim= at all.
			# Fall back to identity for those, so a picker rolled out mid-flight
			# can still release the locks its predecessor left. Drop this once no
			# pre-#7 picker is in service.
			if [ \$ok -eq 0 ] && ! grep -q 'claim=' \"\$O\" 2>/dev/null; then
				grep -q '$ME' \"\$O\" 2>/dev/null && ok=1
			fi
			[ \"${FORCE:-0}\" = 1 ] && ok=1
			if [ \$ok -eq 1 ]; then
				rm -rf \"$LOCK\"; echo released
				# Issue #38, live twice on 2026-08-28 (an unattended timedemo
				# on imac-2019, Quake2 and Aleph One running at once on
				# mini-g4): a release must not leave a game running behind
				# it. TERM ONLY, no escalation. old-mac-quake3-3f caught this
				# BEFORE it shipped, quoting their own measured hardware
				# hazard (docs/adr/0009, scripts/CLAUDE.md there):
				# `killall -KILL` on a rendering fullscreen engine sticks it
				# in uninterruptible GPU-driver exit (ps state E) and hangs
				# the WHOLE WindowServer until a physical reboot -- measured
				# on the Rage128/GeForce2/Radeon9200/9600 driver generation
				# this fleet's vintage PowerPC hosts actually run. This
				# picker has no per-host safe/unsafe list and is shared
				# across every architecture in the fleet, so there is no
				# escalation this file can safely perform on its own -- a
				# survivor gets a loud warning instead, matching
				# smoke-dmg.sh's own precedent of reboot-and-verify rather
				# than KILL for exactly this case. Recovering a wedged host
				# needs a targeted, host-aware reboot, which is out of scope
				# for a release call and belongs in a bench script that
				# already knows which hosts are safe to force.
				pids=\$(ps ax -o pid,command= 2>/dev/null | grep -E \"$GAME_PROC_REGEX\" | grep -vE 'grep|makewhatis' | awk '{print \$1}')
				if [ -n \"\$pids\" ]; then
					echo \"pick-bench-host: quitting lingering game process(es) on release: \$pids\" >&2
					kill -TERM \$pids 2>/dev/null
					sleep 3
					survivors=\"\"
					for pid in \$pids; do
						kill -0 \"\$pid\" 2>/dev/null && survivors=\"\$survivors \$pid\"
					done
					if [ -n \"\$survivors\" ]; then
						echo \"pick-bench-host: WARNING: process(es)\$survivors ignored TERM and were left running.\" >&2
						echo \"  NOT sending KILL: on this fleet's vintage GPU hardware that can wedge the\" >&2
						echo \"  whole WindowServer until a physical reboot. Investigate and quit by hand,\" >&2
						echo \"  or use a host-aware reboot recovery if the host is known safe to force.\" >&2
					fi
				fi
				# Issue #39, user directive 2026-08-28: keep fleet machines tidy,
				# not just idle -- clear (or at least flag) cruft a session left
				# behind before releasing. Same choke point as the game check
				# above, same WARN-don't-delete shape: a script deleting a file on
				# someone else's machine without knowing what it is is a worse
				# failure than leaving it (measured live 2026-08-28: quakespasm's
				# own results.csv/raw logs are INTENTIONAL leftovers on some
				# hosts, so blind deletion would destroy real data). Scoped to
				# the two concrete patterns actually measured today: a stale DMG
				# left on the Desktop (quad-tiger's Half-Life DMG) and a stray
				# file dropped straight in /tmp (g5-desktop's g5-postreboot.png,
				# nobody's -- flagged cross-repo, never claimed). Both are places
				# a deploy/verify step commonly writes and rarely cleans up.
				# Plain glob loops, not find -- POSIX sh, no GNU-only flags,
				# same portability reasoning as clear-launch-quarantine.sh's
				# own walk. Also sidesteps a real difference measured
				# 2026-08-28: a sandboxed dev shell can block find's
				# directory-traversal syscalls on /tmp while still allowing
				# plain readdir-based globbing to see the exact same files --
				# this fleet's actual Macs are never sandboxed, but the glob
				# form works identically either way, so there is no reason to
				# carry the fragile one.
				cruft=\"\"
				for f in \"\$HOME\"/Desktop/*.dmg \"\$HOME\"/Desktop/*.DMG \"\$HOME\"/Desktop/*.app; do
					[ -e \"\$f\" ] && cruft=\"\$cruft
\$f\"
				done
				for f in /tmp/*; do
					[ -f \"\$f\" ] && cruft=\"\$cruft
\$f\"
				done
				cruft=\"\$(printf '%s' \"\$cruft\" | sed '/^\$/d')\"
				if [ -n \"\$cruft\" ]; then
					echo \"pick-bench-host: cruft left on \$(hostname -s 2>/dev/null || echo host) at release:\" >&2
					echo \"\$cruft\" | while IFS= read -r f; do
						echo \"  \$(ls -ld \"\$f\" 2>/dev/null || echo \"\$f\")\" >&2
					done
					echo \"  Not deleting anything -- some of this may be intentional (a port's own\" >&2
					echo \"  results/logs). Clear it yourself if it is yours, or ask whoever's is it.\" >&2
				fi
			else
				echo 'not ours; leaving it' >&2; exit 1
			fi
		else
			echo 'no lock held'
		fi
	" "&1"
}

# Claim $1, run the rest, release it however that ends.
#
# WHY THIS EXISTS rather than an --acquire plus a trap in every caller: seven of
# the fleet scripts already install their own `trap ... EXIT`, and bash traps
# REPLACE rather than compose. A release trap added at the top of one of those
# scripts is silently discarded the moment the script installs its own, and the
# machine stays claimed until the 90 minute stale reclaim. Making the lock the
# property of the INVOCATION removes that whole class of mistake: the caller
# never has to remember to release, and cannot clobber the release by accident.
cmd_run() {
	local h="$1" label="$2" rc
	shift 2
	[ "${1:-}" = "--" ] && shift
	[ "$#" -gt 0 ] || { echo "usage: --run HOST LABEL -- CMD [ARGS...]" >&2; return 2; }
	# BENCH_NO_LOCK=1 runs the command WITHOUT claiming, for debugging the picker
	# itself. Honoured here so there is ONE implementation of the bypass that says
	# out loud it happened, instead of N silent per-repo copies. Issue #11.
	#
	# Loud on purpose. This is the only sanctioned way to work around the fleet's
	# only arbitration, and until now a run that bypassed the lock was
	# indistinguishable from one that never needed it: no warning, no record,
	# nothing to grep.
	#
	# Deliberately NOT honoured by --acquire. Acquire's whole job is to claim, and
	# a caller that is told "acquired" while holding nothing would go on to use a
	# machine it does not own, which is worse than not having the hatch.
	if [ "${BENCH_NO_LOCK:-0}" = 1 ]; then
		echo "pick-bench-host: BENCH_NO_LOCK=1, running on $h WITHOUT claiming it." >&2
		echo "  Nothing is arbitrating this machine for the next command. This is" >&2
		echo "  for debugging the picker, NOT for getting past a host someone holds." >&2
		"$@"
		return $?
	fi
	# One invocation, one nonce, so the release below can only ever remove the
	# lock this invocation created. This is the case issue #7 called live: a
	# predecessor's EXIT trap firing after a successor in the same repo had
	# claimed the same host.
	[ -n "$CLAIM" ] || CLAIM="$(new_claim)"
	cmd_acquire "$h" "$label" >/dev/null || return 1
	# Tell the command it is running inside a claim, naming the host. Scripts
	# guard their own re-exec with
	#     [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ]
	# so without this a script run under --run that calls ANOTHER claiming script
	# hits a nested acquire on a host we already hold. The lock is a bare mkdir
	# and not reentrant, so the inner claim fails, and callers commonly degrade
	# that to a warning rather than an error.
	#
	# Measured by quake3 2026-08-22, by running it rather than reading it:
	# release-check.sh began claiming its host, its nested lsregister-app.sh could
	# no longer claim the same machine, and release-check reported "lsregister
	# inconclusive" on a healthy box. That is the ONE check that catches "the app
	# will not open by double-click", and it degrades to WARN, so it would have
	# stayed broken indefinitely.
	#
	# Naming the host rather than setting a flag is deliberate: a nested step that
	# targets a DIFFERENT machine must still claim that one.
	export RETRO_BENCH_LOCK="$h"
	trap 'cmd_release '"$h"' >/dev/null 2>&1' EXIT INT TERM
	"$@"
	rc=$?
	trap - EXIT INT TERM
	cmd_release "$h" >/dev/null 2>&1
	return $rc
}

case "${1:---status}" in
	--status)      shift; cmd_status "$@" ;;
	--acquire)     cmd_acquire "${2:?usage: --acquire HOST [LABEL]}" "${3:-bench}" ;;
	--run)         h="${2:?usage: --run HOST LABEL -- CMD ...}"; l="${3:-bench}"
	               shift 3; cmd_run "$h" "$l" "$@" ;;
	--release)     cmd_release "${2:?usage: --release HOST}" ;;
	--release-all)
	               # Walks all fourteen hosts. On the identity-only path that is
	               # one command that can drop every claim a sibling session in
	               # this repo holds, across the whole fleet, silently. Nothing in
	               # any repo calls it from code, so requiring an explicit
	               # override costs nothing. A session that died without releasing
	               # is already covered by the stale reclaim after STALE_SECS.
	               if [ -z "$CLAIM" ] && [ "${FORCE:-0}" != 1 ]; then
	                       echo "pick-bench-host: --release-all cannot tell two sessions in $REPO_NAME apart." >&2
	                       echo "  Use FORCE=1 --release-all to override, or BENCH_LOCK_CLAIM to scope it." >&2
	                       exit 2
	               fi
	               for h in $BENCH_HOSTS; do echo "$h: $(cmd_release "$h")"; done ;;
	-h|--help)     sed -n '2,45p' "$0" ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
