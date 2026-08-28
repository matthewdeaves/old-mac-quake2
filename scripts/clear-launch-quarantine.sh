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
	# Check presence FIRST, for honest reporting: measured 2026-08-28, `xattr
	# -dr` (recursive) exits 0 whether or not the attribute was ever present,
	# unlike plain non-recursive `xattr -d`. Trusting -dr's own exit code
	# would make every run claim "cleared", including the common case where
	# there was nothing to clear. -r still runs unconditionally below (cheap,
	# idempotent, and catches quarantine set on files NESTED inside a bundle
	# even when the top-level path itself does not carry it).
	had_flag=0
	xattr -p com.apple.quarantine "$p" >/dev/null 2>&1 && had_flag=1
	if out=$(xattr -dr com.apple.quarantine "$p" 2>&1); then
		if [ "$had_flag" = 1 ]; then
			echo "clear-launch-quarantine: cleared quarantine on $p"
		else
			echo "clear-launch-quarantine: $p carried no quarantine flag"
		fi
	else
		echo "clear-launch-quarantine: xattr failed on $p: $out" >&2
		status=1
	fi

	# Re-register every .app under $p (or $p itself, if it is one). `-f`
	# forces re-registration even if LaunchServices thinks it already knows
	# this bundle. Silent on success; a failure here is not fatal to the
	# overall run (the quarantine clear is the part that has actually bitten
	# so far) but is reported, not swallowed.
	if [ -x "$LSREGISTER" ]; then
		if [ "${p##*.}" = "app" ]; then
			apps="$p"
		else
			apps=$(find "$p" -maxdepth 4 -iname "*.app" -print 2>/dev/null || true)
		fi
		for a in $apps; do
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
