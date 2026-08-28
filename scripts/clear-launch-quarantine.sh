#!/bin/sh
# clear-launch-quarantine.sh - strip com.apple.quarantine from a built
# artifact and re-register any .app bundles under it with LaunchServices.
#
# ============================================================================
# CANONICAL COPY. This file lives in old-mac-build-host and is distributed to
# the port repos by scripts/sync-shared-scripts.sh. Edit it HERE and re-run
# that script; do not edit the copies. See docs/adr/0001 -- this is a
# PRIMITIVE (a path in, nothing product-specific), not a driver: it does not
# know what a DMG or an app bundle belongs to.
# ============================================================================
#
# WHY THIS EXISTS (issue #34, escalated live 2026-08-28): a DMG readme
# telling a person to run `xattr -dr com.apple.quarantine` by hand is not a
# fix -- the person testing a release is not going to run a manual step, and
# on that day was not even going to be there. The fix has to be inside the
# packaging or deploy script itself.
#
# WHAT COM.APPLE.QUARANTINE ACTUALLY DOES: it is set by the browser (or curl
# with a modern LaunchServices call, or Finder unzip) on anything downloaded
# from the internet. Gatekeeper checks it at first launch. For an unsigned,
# unnotarized build -- everything this fleet ships -- that check cannot
# succeed, so the person sees "cannot be opened because Apple cannot check it
# for malicious software" or similar, on a perfectly good build. Measured
# 2026-08-28: a real published release DMG downloaded via Chrome carried
# `com.apple.quarantine: 0081;...`; the ALREADY-INSTALLED .app in
# /Applications from an earlier drag-and-drop carried no xattr at all. So the
# flag does not reliably survive a Finder copy in this fleet's own
# experience, but nothing here should depend on that being true every time --
# hence clearing it explicitly rather than assuming Finder will.
#
# WHY LSREGISTER TOO: a duplicate or stale LaunchServices registration for a
# rebuilt app at the same path can make Finder open the WRONG (old) copy, or
# refuse to open at all, independent of the quarantine flag. `lsregister -f`
# forces a fresh registration. Cheap and idempotent; run it whether or not a
# quarantine flag was found.
#
# usage:
#   scripts/clear-launch-quarantine.sh PATH [PATH...]
#     PATH is a .dmg, a .app bundle, or a directory containing either.
#     Recurses into directories and re-registers every .app found.
#
# exit: 0 if every path was processed (even if nothing needed clearing),
#       2 on a bad argument, non-zero if xattr/lsregister themselves fail.
#
# Deliberately NOT a "host:" self-contained-over-ssh script (see README.md's
# convention for those): this runs on whichever machine packages or deploys
# the artifact -- the build host doing `make-dmg.sh`, or the target Mac doing
# `deploy-dmg.sh` -- as a local step in that script, not piped over ssh.
set -eu

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ "$#" -ge 1 ] || { echo "usage: clear-launch-quarantine.sh PATH [PATH...]" >&2; exit 2; }

status=0

clear_one() {
	p="$1"
	if [ ! -e "$p" ]; then
		echo "clear-launch-quarantine: $p does not exist" >&2
		status=1
		return
	fi
	# Presence check: NOT via -p's or -d's or -dr's exit code. Measured
	# 2026-08-28, two different lies on two different xattr builds -- modern
	# xattr's `-dr` exits 0 whether or not the attribute was ever present, and
	# Leopard/PPC's `-p` exits 0 for an attribute that does NOT exist (checked
	# directly: prints nothing, no error, rc 0). The one thing that actually
	# reflects reality on both is `-l`'s printed output, so that is the only
	# thing this script trusts for presence, before OR after removal.
	has_quarantine() { xattr -l "$1" 2>/dev/null | grep -q '^com\.apple\.quarantine:'; }
	# Recursive version, for the post-removal check: a top-level-only check
	# would miss a flag that survived on a file NESTED inside $p, which is
	# exactly the case the manual walk above exists to fix -- checking only
	# as deep as the fix claims to reach would let that bug hide.
	any_quarantine() {
		find "$1" 2>/dev/null | while IFS= read -r f; do
			has_quarantine "$f" && echo found
		done | grep -q found
	}

	had_flag=0
	has_quarantine "$p" && had_flag=1

	# `-r` itself is not universal: measured live 2026-08-28 on g5-desktop
	# (Leopard/PPC), `xattr -dr` prints usage and exits 64, leaving the flag
	# in place -- that xattr predates the -r flag entirely. There is no
	# Gatekeeper on PPC to need this in the first place, but a generic deploy
	# step must not blow up there either. Try the fast recursive form first;
	# fall back to a manual walk (POSIX `find`, no GNU-only flags) applying
	# non-recursive `-d` per file, which has existed since Panther. Both are
	# `|| true`d: under `set -e`, an unguarded failing command here would
	# abort the whole script rather than fall through to the walk.
	xattr -dr com.apple.quarantine "$p" >/dev/null 2>&1 || true
	find "$p" 2>/dev/null | while IFS= read -r f; do
		xattr -d com.apple.quarantine "$f" >/dev/null 2>&1 || true
	done

	# Verify rather than trust either removal path's exit code -- only the
	# actual post-state, read the same way as the presence check above,
	# decides success.
	if has_quarantine "$p"; then
		echo "clear-launch-quarantine: quarantine flag survived on $p" >&2
		status=1
	elif [ "$had_flag" = 1 ]; then
		echo "clear-launch-quarantine: cleared quarantine on $p"
	else
		echo "clear-launch-quarantine: $p carried no quarantine flag"
	fi

	# Re-register every .app under $p (or $p itself, if it is one). `-f`
	# forces re-registration even if LaunchServices thinks it already knows
	# this bundle. Silent on success; a failure here is not fatal to the
	# overall run (the quarantine clear is the part that has actually bitten
	# so far) but is reported, not swallowed.
	if [ -x "$LSREGISTER" ]; then
		if [ "${p##*.}" = "app" ]; then
			printf '%s\n' "$p"
		else
			find "$p" -maxdepth 4 -iname "*.app" -print 2>/dev/null
		fi | while IFS= read -r a; do
			# NOT `for a in $apps`: this fleet ships bundle names with spaces
			# ("Marathon 2.app", "Marathon Infinity.app" -- flagged to the repo
			# that ships them as alephone#10, measured live 2026-08-28). Word-
			# splitting broke one path into
			# two nonsense ones and lsregister silently scanned neither. A
			# `find | while read` loop treats each line as one path
			# regardless of spaces inside it, same idiom the -r fallback walk
			# above already uses for the same reason.
			[ -n "$a" ] || continue
			"$LSREGISTER" -f "$a" 2>&1 | grep -v '^$' >&2 || true
			echo "clear-launch-quarantine: re-registered $a"
		done
	fi
}

for arg in "$@"; do
	clear_one "$arg"
done

exit "$status"
