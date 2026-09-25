#!/bin/bash
# shared.sh - run a canonical old-mac-build-host script at THIS repo's pinned
# revision, from a read-only cache. Issue #105: replaces copying
# pick-build-host.sh/pick-bench-host.sh/etc into a port tree and committing
# the copy every time the canonical one changes.
#
# usage (from a port repo): scripts/shared.sh <script> [args...]
#   e.g. scripts/shared.sh pick-bench-host.sh --pick mini-g4
#        scripts/shared.sh deploy-dmg.sh quake3 /path/to.dmg
#        scripts/shared.sh --resolve pick-bench-host.sh   (fetch, print cached path, no exec)
#
# build-host#118: a shared script that itself depends on ANOTHER shared
# script by a $SELF_DIR-relative path (deploy-dmg.sh, smoke-dmg.sh and
# bench-evidence.sh each re-exec under a co-located pick-bench-host.sh to
# claim the host lock) breaks on a stone-cold cache: SELF_DIR is this pin's
# cache dir once fetched via shared.sh, and the dependency is only there if
# something ELSE already warmed the same cache first. `--resolve` lets such
# a script pre-warm its own dependency instead of silently finding it
# missing and skipping whatever guard depended on it (deploy-dmg.sh's case:
# skipping the host-lock claim entirely, with no error). RETRO_SHARED_WRAPPER
# (exported below, alongside RETRO_SHARED_CALLER_REPO) is this wrapper's own
# absolute path, so an execed script can call back into it for exactly this.
#
# WHAT THIS REPLACES
# -------------------
# Before #105, sync-shared-scripts.sh --write copied canonical scripts INTO
# five port trees, so a canonical bugfix left five dirty working trees for
# each port to notice, commit and push (2026-09-25: the #103 EXPECT_OS fix
# sat uncommitted in five repos at once). This wrapper is the opposite
# direction: a port repo carries one line (shared-scripts.pin) instead of a
# copy of every script, this wrapper fetches the pinned revision on demand,
# and bumping the pin is that port's own one-line, deliberate commit.
#
# HOW IT RESOLVES A SCRIPT
# -------------------------
# 1. Read shared-scripts.pin from this repo's root: one line, a commit SHA or
#    an annotated/lightweight tag in old-mac-build-host (shared-vN, see
#    docs/adr in old-mac-build-host for the tagging scheme). A tag is
#    preferred: it is what sync-shared-scripts.sh's drift count reads.
# 2. Locate the old-mac-build-host checkout: $OLDMAC_BUILDHOST_REPO if set,
#    else a sibling directory of this repo's root (../old-mac-build-host).
#    This wrapper only runs on a machine that has both checkouts side by
#    side (the workstation orchestrates every fleet script; it never needs
#    to run on a build mini itself). u25's cron copy is a HOST_TARGETS case,
#    unrelated to this wrapper.
# 3. Extract scripts/<script> as it existed AT THAT PIN with
#    `git show <pin>:scripts/<script>` into a cache directory keyed by the
#    pin, so two different pins (two ports on different revisions, or one
#    port mid-bump) never collide and a pin's cached content is immutable
#    once fetched, no atomic-replace-under-a-running-shell hazard like
#    sync-shared-scripts.sh's direct-copy install, because nothing here ever
#    overwrites a path a previous fetch already wrote.
# 4. exec the cached copy with the remaining arguments.
#
# A missing pin, an unreachable old-mac-build-host checkout, or a script that
# does not exist at that pin are all fatal with a specific message -- this is
# meant to fail loudly the first time a port's environment is not set up
# right, not silently fall back to some other copy.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$SELF/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SELF/.." && pwd)"
PIN_FILE="$REPO_ROOT/shared-scripts.pin"

usage() {
	echo "usage: $(basename "$0") [--resolve] <script> [args...]" >&2
	echo "       reads $PIN_FILE for the pinned revision" >&2
	echo "       --resolve <script>: fetch into cache, print the cached path, don't exec" >&2
	exit 2
}

RESOLVE_ONLY=0
if [ "${1:-}" = "--resolve" ]; then
	RESOLVE_ONLY=1
	shift
fi

SCRIPT="${1:-}"
[ -n "$SCRIPT" ] || usage
shift

case "$SCRIPT" in
*/*)
	echo "shared.sh: <script> must be a bare basename, not a path ($SCRIPT)" >&2
	exit 2
	;;
esac

if [ "$RESOLVE_ONLY" -eq 1 ] && [ "$#" -gt 0 ]; then
	echo "shared.sh: --resolve takes no script arguments ($*)" >&2
	exit 2
fi

[ -r "$PIN_FILE" ] || {
	echo "shared.sh: no pin file at $PIN_FILE" >&2
	echo "           create one: echo shared-v1 > shared-scripts.pin" >&2
	exit 1
}
PIN="$(tr -d '[:space:]' < "$PIN_FILE")"
[ -n "$PIN" ] || {
	echo "shared.sh: $PIN_FILE is empty" >&2
	exit 1
}

BUILDHOST_REPO="${OLDMAC_BUILDHOST_REPO:-$REPO_ROOT/../old-mac-build-host}"
[ -d "$BUILDHOST_REPO/.git" ] || {
	echo "shared.sh: no old-mac-build-host checkout at $BUILDHOST_REPO" >&2
	echo "           set OLDMAC_BUILDHOST_REPO if it is not a sibling directory" >&2
	exit 1
}

RESOLVED="$(git -C "$BUILDHOST_REPO" rev-parse --verify -q "${PIN}^{commit}" 2>/dev/null)" || {
	echo "shared.sh: pin '$PIN' does not resolve to a commit in $BUILDHOST_REPO" >&2
	exit 1
}

CACHE_ROOT="${RETRO_SHARED_CACHE:-$HOME/.cache/retro-shared}"
CACHE="$CACHE_ROOT/$RESOLVED"
DST="$CACHE/$SCRIPT"

if [ ! -r "$DST" ]; then
	mkdir -p "$CACHE" || exit 1
	# Same atomic-install shape as sync-shared-scripts.sh: temp file BESIDE the
	# destination, then rename. Content-addressed by resolved commit means no
	# two pins ever fight over the same path, but a second concurrent caller
	# fetching the SAME pin for the first time must not see a half-written file.
	TMP="$(mktemp "$CACHE/.fetch.XXXXXX")" || exit 1
	if ! git -C "$BUILDHOST_REPO" show "$RESOLVED:scripts/$SCRIPT" > "$TMP" 2>/dev/null; then
		rm -f "$TMP"
		echo "shared.sh: scripts/$SCRIPT not found at pin $PIN ($RESOLVED) in $BUILDHOST_REPO" >&2
		exit 1
	fi
	chmod +x "$TMP"
	mv -f "$TMP" "$DST"
fi

# build-host#119: pick-build-host.sh/pick-bench-host.sh derive REPO_NAME from
# their own file's path to build their lock-owner identity (ME) -- correct
# for a copied script, but exec'd from $DST above they'd see this cache
# directory's basename ("retro-shared") instead of the real calling port,
# colliding every migrated port's lock ownership together. We already know
# the real caller here (REPO_ROOT, resolved from THIS wrapper's own path,
# before the exec below); export it so those two scripts can prefer it over
# their own path-derived guess. Every other script this wrapper runs ignores
# an env var it doesn't read, so this is a no-op for them.
RETRO_SHARED_CALLER_REPO="$(basename "$REPO_ROOT")"
export RETRO_SHARED_CALLER_REPO

# build-host#118: this wrapper's own absolute path, so a script it execs can
# call back into it (e.g. `"$RETRO_SHARED_WRAPPER" --resolve pick-bench-host.sh`)
# to pre-warm a sibling shared script into this same cache, instead of trusting
# a $SELF_DIR-relative path that only resolves if something else already
# fetched it this session.
export RETRO_SHARED_WRAPPER="$SELF_PATH"

if [ "$RESOLVE_ONLY" -eq 1 ]; then
	echo "$DST"
	exit 0
fi

exec "$DST" "$@"
