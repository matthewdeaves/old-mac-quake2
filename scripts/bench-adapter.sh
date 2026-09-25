#!/usr/bin/env bash
# scripts/bench-adapter.sh -- quake2's port adapter for the shared bench-evidence
# contract (build-host#104). Port-owned, like dmg-port.conf/dmg-hooks.sh: never
# synced from old-mac-build-host, never edited there. Contract:
# old-mac-build-host/docs/bench-evidence.md. Sourced by scripts/bench-evidence.sh.
#
# Wraps scripts/bench.sh, which already encodes every safety rail this port
# needs: the per-host TIMEOUT/COOLDOWN table, the iMac G5 R300/Leopard
# non-native-fullscreen hazard guard (docs/adr/0008), the shared-fleet busy
# check, and per-host TARGET metadata. This adapter does not re-implement any
# of that -- it runs bench.sh for exactly one run and reads the same
# qconsole.log bench.sh itself already produces.
#
# RETRO_BENCH_LOCK is already exported by bench-evidence.sh (to $HOST) before
# this file is sourced, so bench.sh's own re-exec-under-the-picker check
# (bench.sh:120) sees a matching claim and does not try to claim the host a
# second time.

PORT=quake2

# bench-evidence.sh always does "$HOME/$INSTALL_BIN" (old-mac-build-host#107 --
# the contract doc says INSTALL_BIN may be absolute, but the script does not
# special-case a leading '/'). Quake2's install is root-level
# (/Applications/Quake2/Quake2.app, scripts/deploy.sh:308), not under any
# user's $HOME, so this is a path-traversal value that resolves correctly
# rather than a real absolute path -- same open bug, same trick, as quake3's
# adapter. Verified $HOME is /Users/<name> (2 components) on every active
# bench host (mini-g4, imac-g5, mini-sl, mini-intel, mini-intel2, imac-2019).
# Switch back to the plain absolute path once #107 is fixed.
INSTALL_BIN='../../Applications/Quake2/Quake2.app/Contents/MacOS/quake2'

BENCH_DEMO="${BENCH_DEMO:-demo1}"

# Resolution is never guessed here, for the same reason as quake3's adapter
# (docs/adr/0008): bench.sh itself REFUSES a non-native fullscreen switch on
# imac-g5 (the R300/Leopard hard-hang hazard), so this adapter does not add a
# second, silently-guessed source of truth -- it just forwards the caller's
# BENCH_RES to bench.sh's own required WxH argument and lets that guard do
# its job.
bench_launch() {
	local host="$1" round="$2" workdir="$3"
	local self_dir raw_dir out rc fps log_name

	if [ -z "${BENCH_RES:-}" ]; then
		{
			echo "bench-adapter: BENCH_RES=<WxH> required -- the host's confirmed"
			echo "  validated bench resolution (see the per-machine cfg comments and"
			echo "  docs/adr/0008 for the imac-g5 R300 hazard: only 1440x900 or"
			echo "  G5_WINDOWED=1 are safe there)."
		} > "$workdir/log.txt"
		echo fps > "$workdir/stats.unit"
		echo "EXIT=2"
		echo "PID="
		return
	fi

	self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	raw_dir="$workdir/raw"
	mkdir -p "$raw_dir"

	# RUNS=1: bench-evidence.sh/bench-compare.sh own the round and cold-start
	# discipline (the first round per side is dropped in bench-compare.sh), so
	# one evidence bundle is one bench.sh run, not bench.sh's own 3-run
	# median. BENCH_CSV/BENCH_RAW_DIR redirected into the evidence workdir so
	# a bench-evidence pass never writes into the git-tracked
	# benchmarks/results.csv or benchmarks/raw/ -- the same redirection the
	# Jenkins bench jobs already use (.claude/rules/commands.md).
	out="$(BENCH_CSV="$workdir/results.csv" BENCH_RAW_DIR="$raw_dir" \
		"$self_dir/bench.sh" "$host" "$BENCH_DEMO" "$BENCH_RES" 1 2>&1)"
	rc=$?
	printf '%s\n' "$out" > "$workdir/log.txt"

	log_name="$(ls -t "$raw_dir"/*_run1.log 2>/dev/null | head -1)"
	[ -n "$log_name" ] && cp "$log_name" "$workdir/engine.log"

	fps="$(printf '%s\n' "$out" | grep -oE -- '-> [0-9]+\.[0-9]+ fps' | tail -1 | awk '{print $2}')"
	[ -n "$fps" ] && printf '%s\n' "$fps" > "$workdir/stats.txt"
	echo fps > "$workdir/stats.unit"

	echo "EXIT=$rc"
	echo "PID="
}

# bench.sh always blocks until its one run completes or its per-host TIMEOUT
# fires (see the TARGET case table in bench.sh), so bench_launch never leaves
# PID non-empty and this is never called live -- kept only to satisfy the
# adapter contract, same as quake3's.
bench_liveness() {
	:
}

# Read back from the SAME live qconsole.log bench.sh's own run just wrote on
# the target (~/.yq2/baseq2/qconsole.log, FS_Gamedir() -- see bench.sh's
# header comment), not the requested flags. This is a fresh, independent
# read rather than reusing bench_launch's local copy, because
# bench_effective_config only receives $host (bench-evidence.sh:151), and
# bench_launch ran inside a command substitution subshell whose own variables
# don't survive back into this call.
bench_effective_config() {
	local host="$1" cmd out
	cmd='grep -E "GL_RENDERER|^\"gl_bloom\" is |^\"gl_bloom_darken\" is |^\"gl_msaa_samples\" is |^\"gl_mode\" is |^\"gl_customwidth\" is |^\"gl_customheight\" is |^\"vid_fullscreen\" is |^\"vid_desktopfullscreen\" is |^\"gl_swapinterval\" is " ~/.yq2/baseq2/qconsole.log 2>/dev/null'
	if [ "$host" = workstation ]; then
		out="$(bash -c "$cmd")"
	else
		out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$cmd" 2>/dev/null)"
	fi
	printf '%s\n' "$out" | sed -n \
		-e 's/^GL_RENDERER: */renderer=/p' \
		-e 's/^"\([a-zA-Z_0-9]*\)" is "\([^"]*\)".*/\1=\2/p'
}
