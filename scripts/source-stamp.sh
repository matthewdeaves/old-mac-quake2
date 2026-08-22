#!/bin/sh
# source-stamp.sh - what a build was actually built FROM.
#
# SOURCED, NOT RUN. There is no main; it defines five functions. Canonical copy
# lives in old-mac-build-host and is distributed to the ports; see THE SHARED
# SURFACE below before changing anything in it.
#
# WHY THIS EXISTS
# ---------------
# arm64 is the one slice no build mini can produce. Lion's Xcode predates ARM64
# by seven years, so that slice is built on the workstation, carried over, and
# fused. Every other slice is recompiled in place on each run and cannot drift
# from the source tree. arm64 can, and nothing looked.
#
# Measured in old-mac-quake2 on 2026-08-22: an arm64 tree built at 09:06, shared
# source patched at 12:09, the fat build run at 12:12. It printed "arm64 slice
# present: fusing SIX", lipo -archs gave the correct six slices, and the arm64
# member was the 09:06 build. old-mac-quake2#17 has the reproduction; that repo
# wrote the original of this file and the reasoning below is theirs.
#
# Four cheaper checks were ruled out first:
#   - file exists          the original bug
#   - mtime / freshness    a stale object can carry a FRESH timestamp; that is
#                          how old-mac-halflife shipped stale PowerPC slices on
#                          31 July 2026 with every check passing
#   - commit id            builds rsync the WORKING TREE, not a commit, and an
#                          uncommitted tree is the normal state here
#   - commit id + dirty    records THAT the tree was dirty, not WHICH dirty tree
#
# So: hash the content of the source that goes IN to the build.
#
# THE SHARED SURFACE
# ------------------
# This file knows nothing about products, slices, paths or repo layout, and it
# must stay that way, because it is byte-identical in five repos and a drift
# check enforces that.
#
# In particular the EXCLUDE LIST IS A PARAMETER, not a constant. That is the one
# real change from the old-mac-quake2 original, which carried its own layout
# (build/, benchmarks/, prereqs/, reference/) in a variable inside the file. Those
# names are that port's, not the fleet's. Baking any port's layout in here would
# either make the copies drift or grow per-repo branching, and both are worse
# than no sharing. Measured arm64 driver counts, which is the same argument:
# old-mac-halflife 7, old-mac-quake3 2, old-mac-quake2 1, old-mac-quakespasm 1.
#
# Each port keeps its own exclude list in its own build script and passes it in.
# Pass the SAME list to source_stamp_compute and source_stamp_rsync_excludes, so
# what is hashed and what is copied cannot disagree. A file outside the set
# cannot affect a build; a file inside it must change the hash.
#
# There is deliberately NO default list. An omitted list is an error, not an
# empty one. A silently over-broad hash covers build outputs, changes on every
# run, fires constantly, and gets switched off, which is worse than no check.
#
# LIST FORMAT: newline-separated, NOT space-separated. Reading it with
# `for e in $VAR` would depend on word-splitting, which sh and bash do and zsh
# does NOT; under zsh the whole list collapses to one word and nothing is
# pruned. Read it with `while IFS= read -r`, which behaves the same in all
# three. Verified under sh, bash and zsh.
#
# HASH TOOL: shasum -a 256. Measured across the fleet on 2026-08-22, each box
# claimed through pick-bench-host.sh --run: `md5 -q` is BSD-only, `md5sum` is
# Linux-only and is absent on every Mac here, so no md5 spelling works on both a
# mini and a Linux box. shasum is present on the workstation, on both 10.7.5
# minis and on mini-sl, and on Linux wherever perl is. It is NOT on 10.5.8,
# 10.4.11 or 10.3.9 -- see docs/HOSTS.md. That is fine, because nothing stamps
# on a PowerPC bench machine, but it is why this is not called universal.
# sync-build-lock.sh already hashes with shasum for the same reason.

# WHAT THE CALLER MUST DO, and the one that has already bitten
# --------------------------------------------------------------
# A slice STAGED BY COPYING must have its stamp copied with it. arm64 is the
# only slice that is staged rather than built in place, so it is the only one
# where this arises, and it arises on the one slice the whole check exists for.
#
# old-mac-quake2 hit exactly this on 2026-08-22 (ea922696, fixed in 0b526e06):
# staging copied four artifacts and not SOURCE-STAMP, so the read returned empty
# and the gate refused EVERY six-slice build, current ones included. The gate had
# only ever been tested against the stale build it was written to catch.
#
# Test both directions. A check that refuses good builds gets switched off, and
# that defeats it more thoroughly than never writing it. tests/test-source-stamp.sh
# in old-mac-build-host asserts both, including this staging case.
#
# A DRIVER THAT MUTATES THE TREE IN ORDER TO BUILD MUST STAMP BEFORE THE
# MUTATION. old-mac-quake2, cabeae7e: build-arm64.sh sed-edits the engine
# Makefile to turn three options off, and an EXIT trap reverts it. The stamp was
# computed at the end of the script, which is BEFORE the trap fires, so it hashed
# a Makefile that never exists at rest. Every mini-built slice recorded
# 8e643192b2b9 and arm64 recorded 9896723a7cbd from identical source. Check the
# ordering against where the trap FIRES, not where the write call sits.
#
# BUILD OUTPUT THAT LIVES INSIDE THE SOURCE TREE MUST BE IN THE EXCLUDE LIST.
# Same commit: the engine Makefile's release/ directory was being hashed as
# source, so the hash of an unchanged tree moved depending on whether an arm64
# build had run. old-mac-quakespasm found the same shape in dist/ (4b4aa767).
#
# That exclusion has a trap of its own, because this list is meant to drive the
# rsync too: rsync --delete PROTECTS excluded paths on the receiver, so the
# remote copy of a newly-excluded build directory stops being replaced. quake2 is
# safe only because build.sh:223 runs make clean before every make. Each port
# must check its own equivalent rather than copy that conclusion.

# ---------------------------------------------------------------------------
# source_stamp_rsync_excludes <excludes>
#
# Emit rsync --exclude= flags from the same list the hash uses, so the two
# cannot drift apart. Unquoted on purpose at the call site: rsync wants them as
# separate words.
source_stamp_rsync_excludes () {
	if [ "$#" -lt 1 ]; then
		echo "source_stamp_rsync_excludes: need an exclude list" >&2
		# Fail CLOSED, because returning 2 is not enough here. Every real call is
		# $(source_stamp_rsync_excludes) inside an rsync argument list, and command
		# substitution there DISCARDS the status: the message above goes to stderr
		# and the build carries straight on with no --exclude flags at all, copying
		# .git, build/ and benchmarks/ to the mini. Slow and wrong, but not failed.
		#
		# Measured 2026-08-22: quake2 build.sh:196 and quakespasm build.sh:244 both
		# call it with no argument today. So emit a flag rsync cannot open, which
		# turns a silently wrong copy into a stopped build with a named cause.
		printf -- '--exclude-from=/nonexistent/source-stamp-excludes-missing '
		return 2
	fi
	printf '%s\n' "$1" | while IFS= read -r _e; do
		[ -n "$_e" ] && printf -- '--exclude=%s ' "$_e"
	done
}

# ---------------------------------------------------------------------------
# source_stamp_compute <dir> <excludes>  ->  64 hex chars on stdout
#
# Hashes names AND contents, so a rename changes the result.
#
# LC_ALL=C on the sort: collation is locale-dependent and the workstation and
# the minis disagree. Without it two identical trees hash differently and the
# check reports drift for ever, which is a gate that fires on noise.
#
# set -f around the loop: the list holds globs like *.o, and an unquoted
# expansion would let the shell match them against the cwd instead of passing
# them to find. Prune args are built with set -- so each pattern reaches find as
# one word.
#
# xargs rather than one shasum per file: a per-file spawn over 785 files took
# minutes. Sort FIRST so the order is deterministic, then let xargs preserve it.
# tr to NUL rather than `sort -z`, which Lion's sort does not have. A filename
# containing a newline would break this; none exist in the hashed set, and a
# build would not survive one either.
source_stamp_compute () {
	[ "$#" -ge 2 ] || { echo "source_stamp_compute: need <dir> <excludes>" >&2; return 2; }
	[ -d "$1" ] || { echo "source_stamp_compute: no such directory: $1" >&2; return 2; }
	( cd "$1" || exit 2
	  # Copy the list out of $2 FIRST. `set --` below clears the positional
	  # parameters, and the heredoc that feeds the loop is expanded when the
	  # loop RUNS, not when it is written -- so reading $2 there would read an
	  # empty string, prune nothing, and hash the build output. The quake2
	  # original kept the list in a variable and never met this; making it a
	  # parameter is what introduces it. Caught by the exclude test.
	  _ex="$2"
	  set -f
	  set --
	  _first=1
	  while IFS= read -r _e; do
	  	[ -n "$_e" ] || continue
	  	case "$_e" in
	  		*/) _p="./${_e%/}" ; _t="-path" ;;
	  		*)  _p="$_e"       ; _t="-name" ;;
	  	esac
	  	if [ "$_first" = 1 ]; then set -- "$_t" "$_p"; _first=0
	  	else set -- "$@" -o "$_t" "$_p"; fi
	  done <<EOF
$_ex
EOF
	  set +f
	  if [ "$_first" = 1 ]; then
	  	# Empty list: hash everything. Legal, but the caller asked for it
	  	# explicitly rather than by forgetting an argument.
	  	find . -type f -print
	  else
	  	find . \( "$@" \) -prune -o -type f -print
	  fi \
	  | LC_ALL=C sort \
	  | tr '\n' '\0' \
	  | xargs -0 shasum -a 256 \
	  | shasum -a 256 | cut -d' ' -f1 )
}

# ---------------------------------------------------------------------------
# source_stamp_write <dir> <hash>   writes <dir>/SOURCE-STAMP
#
# cut -d' ' is applied at every shasum call site above, because shasum prints
# "<hash>  <name>" and prints a bare "-" when it reads stdin. A stamp file with
# a dash left in it is the easy mistake here.
source_stamp_write () {
	[ "$#" -ge 2 ] || { echo "source_stamp_write: need <dir> <hash>" >&2; return 2; }
	printf '%s\n' "$2" > "$1/SOURCE-STAMP"
}

# ---------------------------------------------------------------------------
# source_stamp_read <dir>  ->  hash on stdout, empty if there is no stamp
source_stamp_read () {
	[ "$#" -ge 1 ] || { echo "source_stamp_read: need <dir>" >&2; return 2; }
	[ -f "$1/SOURCE-STAMP" ] || return 0
	head -n1 "$1/SOURCE-STAMP" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# source_stamp_verify <dir> <expected>
#
#   0  stamp present and matches
#   1  stamp present and does NOT match      -> the slice is stale
#   3  no stamp at all                       -> unknown, not proven current
#
# 3 rather than 1 for a missing stamp because they are different situations and
# the caller may reasonably treat them differently: a mismatch is a slice built
# from other source, a missing stamp is a slice built before anything stamped.
# Neither is a pass. What to DO about either is the caller's policy, not this
# file's; that is settled per port, not here.
source_stamp_verify () {
	[ "$#" -ge 2 ] || { echo "source_stamp_verify: need <dir> <expected>" >&2; return 2; }
	_got="$(source_stamp_read "$1")"
	[ -n "$_got" ] || return 3
	[ "$_got" = "$2" ]
}
