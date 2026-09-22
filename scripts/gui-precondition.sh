#!/bin/bash
# gui-precondition.sh - refuse a GUI smoke/bench launch into a locked console.
#
# ============================================================================
# CANONICAL COPY. Lives in old-mac-build-host and is distributed to the port
# repos by scripts/sync-shared-scripts.sh. Edit it HERE; do not edit the copies.
# ============================================================================
#
# old-mac-build-host#88, 2026-09-22: imac-2019 went black for 90 minutes because
# every display sleep makes loginwindow raise a black shield window (level 2001,
# kLWLockFromDisplayDim), even with "require password" set to never, and
# `sysadminctl -screenLock status` still says off. While the shield is up,
# WindowServer refuses to bring a launched game to the front ("not in the list
# of permittedFrontASNs"), so a fullscreen smoke captures black. Six smokes ran
# into it between 17:52 and 19:24 and reported frames nobody could see.
#
# Measured on imac-2019 (macOS 15.7.9): display asleep means
# CGSSessionScreenIsLocked=Yes in `ioreg -n Root -d1`; `caffeinate -u` wakes
# the display and the shield drops (the key disappears) when no password is
# required. So: wake, then refuse only if the session is STILL locked, which
# means a password stands between the game and the screen. Per the fleet brief,
# a missing display/context precondition means untested, not a pass.
#
# Call it right before the launch, inside the claim:
#     scripts/gui-precondition.sh "$HOST" || exit 1     # over ssh
#     scripts/gui-precondition.sh                        # on this Mac
# exit: 0 ready, 3 screen locked, 2 could not probe (unreachable, no ioreg).
# Display power is reported but never refused: the headless minis (#20) report
# low power with no display attached, and nothing there is a GUI smoke target.
# 10.3-10.7 have no caffeinate; the probe skips the wake there and just reads
# the lock state.
set -uo pipefail

PROBE='
command -v ioreg >/dev/null 2>&1 || { echo "probe: no ioreg"; exit 2; }
if command -v caffeinate >/dev/null 2>&1; then caffeinate -u -t 2; sleep 2; woke=yes; else woke="no caffeinate"; fi
# 10.5+ ioreg takes -n NAME -d1 / -r. Tiger (and Panther) ioreg does not: it
# prints usage, which made the lock check always read "no" there (quake3,
# 2026-09-22). Fall back to the whole -l tree, where the Root node, and so
# IOConsoleUsers, comes first.
if ioreg -n Root -d1 2>/dev/null | grep -q "IOConsoleUsers"; then
	root=$(ioreg -n Root -d1 2>/dev/null)
	dw=$(ioreg -n IODisplayWrangler -r -d1 2>/dev/null | grep "CurrentPowerState" | head -1)
else
	all=$(ioreg -l 2>/dev/null)
	root=$(printf "%s\n" "$all" | sed -n 1,80p)
	dw=$(printf "%s\n" "$all" | awk "/IODisplayWrangler/{f=1} f && /CurrentPowerState/{print; exit}")
fi
# Fail closed: no console-session record means we cannot say it is unlocked.
printf "%s\n" "$root" | grep -q "IOConsoleUsers" || { echo "probe: cannot read the console session (ioreg)"; exit 2; }
lock=no
printf "%s\n" "$root" | grep -q "\"CGSSessionScreenIsLocked\" *= *Yes" && lock=yes
disp=$(printf "%s\n" "$dw" | sed -n "s/.*\"CurrentPowerState\" *= *\([0-9][0-9]*\).*/\1/p" | head -1)
echo "probe: wake=$woke locked=$lock display_power=${disp:-none}"
[ "$lock" = yes ] && exit 3
exit 0
'

if [ $# -ge 1 ]; then
	out="$(printf '%s' "$PROBE" | ssh -o ConnectTimeout=8 -o BatchMode=yes "$1" /bin/sh -s 2>&1)"
	rc=$?
	where="$1"
else
	out="$(printf '%s' "$PROBE" | /bin/sh -s 2>&1)"
	rc=$?
	where="this Mac"
fi

case $rc in
	0) echo "gui-precondition: $where ready ($out)" ;;
	3) echo "gui-precondition: $where screen locked; refusing to launch ($out)" >&2
	   echo "  A launch now would run behind loginwindow's shield and capture black." >&2
	   echo "  Someone has to unlock it at the console. See old-mac-build-host#88." >&2 ;;
	*) echo "gui-precondition: could not probe $where ($out)" >&2; rc=2 ;;
esac
exit $rc
