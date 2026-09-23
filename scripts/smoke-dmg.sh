#!/usr/bin/env bash
# smoke-dmg.sh -- launch a port's INSTALLED game on a fleet Mac, the way a
# player would, and say whether it ran. CANONICAL copy lives in
# old-mac-build-host (#96), synced byte-identical into each port; never edit a
# port's copy. Per-port values come from scripts/dmg-port.conf, and a port may
# post-process the verdict with smoke_verdict() in scripts/dmg-hooks.sh.
#
# usage: scripts/smoke-dmg.sh <host> [demo]
#   host  any fleet alias, or `workstation`
#   demo  replaces {DEMO} in SMOKE_ARGS (default SMOKE_DEMO)
#
# How it launches, chosen from the host's OS and users, never from its name:
#  - 10.6+, console user = ssh user: `open -n <app> --args ...` (LaunchServices)
#  - before 10.6: first a bounded bare `open` of the app (what a player's double
#    click does), reported as OPEN_CHECK, then the game is exec'd directly with
#    its args, because `open` has no --args there. A Tiger first-launch consent
#    dialog blocks `open` with nobody to click it; after 30 s it is dismissed and
#    retried, twice (quake3 a581603e). Panther's -10814 after a fresh install is
#    retried every 15 s for up to 180 s (quake3 5165c5df: 20-89 s measured on the G3).
#  - console user != ssh user: direct exec (LaunchServices does nothing then)
#  - SMOKE_ARCH set: direct exec, since `open -n` picks the native slice
# Direct exec runs SMOKE_EXEC (a port's launcher script, e.g. Half-Life's
# xash3d, which picks the per-machine profile), under `arch -SMOKE_ARCH` if set.
#
# Pass: PASS_RE appears in the log, or (no PASS_RE) the game is still alive
# after SMOKE_SECS. Fail: FAIL_RE appears, it exits early, or no pass within
# SMOKE_TIMEOUT. Both can be set per CPU class, e.g. SMOKE_SECS_ppc750=14
# (classes: ppc750 ppc7400 ppc7450 ppc970 x86 arm64, from `machine`).
# Quit: AppleScript quit (bounded), TERM, then KILL only if KILL_OK=yes; it
# always confirms the process is gone. SMOKE_MUTE=yes mutes and restores audio.
# SMOKE_PRE_RM: files (relative to ~) removed before launch, e.g. a stale pid
# file that makes the game open a modal dialog (quake3's ioq3.pid).
#
# Exit: 0 pass, 1 fail, 2 usage/config, 9 untested (game already running,
#       screen locked, no install), others as a port's smoke_verdict returns
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-}"; [ -n "$HOST" ] && [ "$HOST" != -h ] || { sed -n '8,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
ENV_TIMEOUT="${SMOKE_TIMEOUT:-}"; ENV_SECS="${SMOKE_SECS:-}"

CONF="${DMG_PORT_CONF:-$SELF_DIR/dmg-port.conf}"
[ -r "$CONF" ] || { echo "smoke-dmg: no port config at $CONF (see old-mac-build-host#96)" >&2; exit 2; }
OWNED=(); SMOKE_ARGS=(); SMOKE_PRE_RM=(); PROC=; SMOKE_APP=; SMOKE_EXEC=; SMOKE_ARCH=; SMOKE_LOG=; SMOKE_DEMO=
PASS_RE=; FAIL_RE=; KILL_OK=yes; SMOKE_MUTE=no; SMOKE_SECS=10; SMOKE_TIMEOUT=60
# shellcheck source=/dev/null
. "$CONF"
[ -r "$SELF_DIR/dmg-hooks.sh" ] && . "$SELF_DIR/dmg-hooks.sh"
for v in PORT INSTALL_DIR PROC; do
	[ -n "${!v:-}" ] || { echo "smoke-dmg: $CONF must set $v" >&2; exit 2; }
done
INSTALL_DIR="${DEST_DIR:-$INSTALL_DIR}"
if [ -z "$SMOKE_APP" ]; then
	for p in "${OWNED[@]}"; do case "$p" in *.app|*.app\?) SMOKE_APP="${p%\?}"; break ;; esac; done
fi
[ -n "$SMOKE_APP" ] || { echo "smoke-dmg: set SMOKE_APP (no .app in OWNED)" >&2; exit 2; }
[ -n "$SMOKE_EXEC" ] || SMOKE_EXEC="$SMOKE_APP/Contents/MacOS/$PROC"
DEMO="${2:-$SMOKE_DEMO}"

_PICK="$SELF_DIR/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "$PORT smoke-dmg" -- "$0" "$@"
fi

say() { echo "[smoke $HOST] $*"; }
if [ "$HOST" = workstation ]; then run_host() { bash -s; }
else run_host() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" bash -s; }; fi

# A locked or display-dimmed console captures nothing (#88): untested, not failed.
if [ "$HOST" != workstation ] && [ -x "$SELF_DIR/gui-precondition.sh" ]; then
	"$SELF_DIR/gui-precondition.sh" "$HOST"; g=$?
	[ $g -eq 3 ] && { say "UNTESTED: the console is locked"; exit 9; }
	[ $g -ne 0 ] && say "WARN: could not probe the console (gui-precondition rc=$g); going ahead"
fi

ARGS=()
for a in ${SMOKE_ARGS[@]+"${SMOKE_ARGS[@]}"}; do
	a="${a//\{DEMO\}/$DEMO}"; ARGS[${#ARGS[@]}]="${a//\{DEST\}/$INSTALL_DIR}"
done
qarr() { local n="$1"; shift; printf '%s=(' "$n"; [ $# -gt 0 ] && printf ' %q' "$@"; printf ' )\n'; }

OUT="$(mktemp "${TMPDIR:-/tmp}/buildhost-smoke.XXXXXX")" || exit 1
LOG="$(mktemp "${TMPDIR:-/tmp}/buildhost-smokelog.XXXXXX")" || exit 1
trap 'rm -f "$OUT" "$LOG"' EXIT

{ printf 'PORT=%q DEST=%q APP=%q EXE=%q ARCH=%q PROC=%q SLOG=%q PASS_RE=%q FAIL_RE=%q KILL_OK=%q MUTE=%q FORCE=%q ENV_SECS=%q ENV_TIMEOUT=%q\n' \
	"$PORT" "$INSTALL_DIR" "$SMOKE_APP" "$SMOKE_EXEC" "$SMOKE_ARCH" "$PROC" "$SMOKE_LOG" "$PASS_RE" "$FAIL_RE" \
	"$KILL_OK" "$SMOKE_MUTE" "${FORCE:-0}" "$ENV_SECS" "$ENV_TIMEOUT"
  qarr ARGS ${ARGS[@]+"${ARGS[@]}"}
  qarr PRE_RM ${SMOKE_PRE_RM[@]+"${SMOKE_PRE_RM[@]}"}
  # Per-class timings travel as plain assignments; the host picks its own.
  for c in ppc750 ppc7400 ppc7450 ppc970 x86 arm64; do
	for k in SMOKE_SECS SMOKE_TIMEOUT; do
		vn="${k}_$c"; [ -n "${!vn:-}" ] && printf '%s=%q\n' "$vn" "${!vn}"
	done
  done
  printf 'SMOKE_SECS=%q SMOKE_TIMEOUT=%q\n' "$SMOKE_SECS" "$SMOKE_TIMEOUT"
  cat <<'REMOTE'
set -u
case "$DEST" in "~/"*) DEST="$HOME/${DEST#"~/"}" ;; esac
case "$SLOG" in "") ;; "~/"*) SLOG="$HOME/${SLOG#"~/"}" ;; /*) ;; *) SLOG="$DEST/$SLOG" ;; esac
ROOT="$HOME/oldmac/$PORT/deploy"
OUTLOG="$ROOT/smoke-stdout.log"
[ -n "$SLOG" ] || SLOG="$OUTLOG"
[ -d "$DEST/$APP" ] || { echo "VERDICT UNTESTED no $DEST/$APP installed"; exit 0; }

# Not `pid=,command=`: with -c, Tiger prints an empty command column for that.
pids() { ps -axco pid,command 2>/dev/null | awk -v p="$1" 'NR>1{pid=$1; sub(/^ *[0-9]+ +/,""); if ($0==p) print pid}'; }
alive() { [ -n "$(pids "$PROC")" ]; }
# ucomm of every port's game, so a smoke never lands on top of another game.
busy=
for g in xash3d.bin quake2 yquake2 q2ded ioquake3 quakespasm "Aleph One" "$PROC"; do [ -n "$(pids "$g")" ] && busy="$g"; done
if [ -n "$busy" ] && [ "$FORCE" != 1 ]; then echo "VERDICT UNTESTED '$busy' is already running (FORCE=1 overrides)"; exit 0; fi

OS="$(sw_vers -productVersion 2>/dev/null)"; min="${OS#10.}"; min="${min%%.*}"
case "$OS" in 10.*) old=$([ "$min" -lt 6 ] && echo yes || echo no) ;; *) old=no ;; esac
case "$(machine 2>/dev/null || uname -m)" in
	ppc750) CLASS=ppc750 ;; ppc7400) CLASS=ppc7400 ;; ppc7450) CLASS=ppc7450 ;; ppc970) CLASS=ppc970 ;;
	arm64*) CLASS=arm64 ;; *) CLASS=x86 ;;
esac
v="SMOKE_SECS_$CLASS"; SECS="${ENV_SECS:-${!v:-$SMOKE_SECS}}"
v="SMOKE_TIMEOUT_$CLASS"; TMO="${ENV_TIMEOUT:-${!v:-$SMOKE_TIMEOUT}}"
CUSER="$(ls -l /dev/console 2>/dev/null | awk '{print $3}')"; ME="$(id -un)"   # no stat on 10.3
echo "INFO os=$OS class=$CLASS console=$CUSER ssh=$ME secs=$SECS timeout=$TMO"

VOL=
if [ "$MUTE" = yes ]; then
	VOL="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
	case "$VOL" in ''|*[!0-9]*) VOL=; echo "INFO cannot read the volume here, so not muting" ;; *) osascript -e 'set volume output volume 0' >/dev/null 2>&1 ;; esac
fi
# Scratch goes with the run; the log travels back between LOG_BEGIN/LOG_END.
restore() {
	[ -n "$VOL" ] && osascript -e "set volume output volume $VOL" >/dev/null 2>&1
	rm -f "$OUTLOG" "$ROOT/open.err" "$ROOT/open.sample"; rmdir "$ROOT" 2>/dev/null
}
trap restore EXIT
mkdir -p "$ROOT"

quit_game() {
	local n t
	[ -n "$(pids "$PROC")" ] || { echo "QUIT none-running"; return 0; }
	n="$(basename "$APP" .app)"
	osascript -e "tell application \"$n\" to quit" >/dev/null 2>&1 & t=$!
	for _ in 1 2 3 4 5 6; do [ -n "$(pids "$PROC")" ] || break; sleep 1; done
	kill "$t" 2>/dev/null
	[ -n "$(pids "$PROC")" ] || { echo "QUIT clean"; return 0; }
	kill -TERM $(pids "$PROC") 2>/dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(pids "$PROC")" ] || break; sleep 1; done
	[ -n "$(pids "$PROC")" ] || { echo "QUIT term"; return 0; }
	if [ "$KILL_OK" = yes ]; then
		kill -KILL $(pids "$PROC") 2>/dev/null; sleep 2
		[ -n "$(pids "$PROC")" ] || { echo "QUIT kill"; return 0; }
	fi
	echo "QUIT STILL_RUNNING pid $(pids "$PROC")"; return 1
}

# Pre-10.6: does a LaunchServices open start the game at all?
open_check() {
	local round=0 tries=0 k op err
	while :; do
		open "$DEST/$APP" > "$ROOT/open.err" 2>&1 & op=$!
		k=0; while [ $k -lt 30 ]; do alive && break; kill -0 $op 2>/dev/null || break; sleep 1; k=$((k+1)); done
		alive && { echo "OPEN_CHECK ok"; return 0; }
		if ! kill -0 $op 2>/dev/null; then
			wait $op && { sleep 5; alive && { echo "OPEN_CHECK ok"; return 0; }; echo "OPEN_CHECK no-process"; return 1; }
			err="$(sed -n 's/.*returned \(-[0-9]*\).*/\1/p' "$ROOT/open.err" | head -1)"
			if [ "$err" = -10814 ] && [ $tries -lt 12 ]; then
				tries=$((tries+1)); echo "NOTE open -10814, retry $tries in 15s"; sleep 15; continue
			fi
			echo "OPEN_CHECK failed ${err:-no-LS-code}"; return 1
		fi
		round=$((round+1)); why=blocked
		sample $op 2 -file "$ROOT/open.sample" >/dev/null 2>&1 && grep -q LSConsentToLaunch "$ROOT/open.sample" && why=consent-dialog
		rm -f "$ROOT/open.sample"
		echo "NOTE open $why for 30s with no game (round $round); dismissing"
		killall -TERM UserNotificationCenter 2>/dev/null; sleep 3; kill -TERM $op 2>/dev/null
		[ $round -ge 2 ] && { echo "OPEN_CHECK timeout-$why"; return 1; }
	done
}

rm -f "$SLOG"
for p in ${PRE_RM[@]+"${PRE_RM[@]}"}; do rm -f "$HOME/$p"; done
if [ "$old" = no ] && [ "$CUSER" = "$ME" ] && [ -z "$ARCH" ]; then
	MODE=open
	if [ ${#ARGS[@]} -gt 0 ]; then open -n "$DEST/$APP" --args "${ARGS[@]}" > "$OUTLOG" 2>&1
	else open -n "$DEST/$APP" > "$OUTLOG" 2>&1; fi
else
	if [ "$old" = yes ] && [ "$CUSER" = "$ME" ]; then open_check; quit_game >/dev/null; fi
	MODE=exec
	[ -x "$DEST/$EXE" ] || { echo "VERDICT UNTESTED $DEST/$EXE is not executable"; exit 0; }
	( cd "$DEST" && if [ -n "$ARCH" ]; then exec arch "-$ARCH" "$DEST/$EXE" ${ARGS[@]+"${ARGS[@]}"}
	  else exec "$DEST/$EXE" ${ARGS[@]+"${ARGS[@]}"}; fi ) > "$OUTLOG" 2>&1 < /dev/null &
fi
echo "INFO mode=$MODE${ARCH:+ arch=$ARCH}"

t=0; seen=no; verdict=
while [ $t -lt "$TMO" ]; do
	sleep 1; t=$((t+1))
	alive && seen=yes
	if [ -n "$FAIL_RE" ] && grep -Eq "$FAIL_RE" "$SLOG" "$OUTLOG" 2>/dev/null; then verdict="FAIL matched FAIL_RE after ${t}s"; break; fi
	if [ -n "$PASS_RE" ] && grep -Eq "$PASS_RE" "$SLOG" "$OUTLOG" 2>/dev/null; then verdict="PASS matched PASS_RE after ${t}s"; break; fi
	if [ -z "$PASS_RE" ] && [ $seen = yes ] && [ $t -ge "$SECS" ] && alive; then verdict="PASS alive ${t}s"; break; fi
	if [ $seen = yes ] && ! alive && [ -z "$PASS_RE" ]; then verdict="FAIL exited after ${t}s"; break; fi
	if [ $seen = yes ] && ! alive && [ -n "$PASS_RE" ]; then
		grep -Eq "$PASS_RE" "$SLOG" "$OUTLOG" 2>/dev/null && verdict="PASS matched PASS_RE after ${t}s" || verdict="FAIL exited after ${t}s without PASS_RE"; break
	fi
done
[ -n "$verdict" ] || verdict="FAIL no pass within ${TMO}s (process seen: $seen)"
quit_game || verdict="FAIL $verdict; game would not quit"
echo "VERDICT $verdict"
echo "LOG_BEGIN"; tail -n 300 "$SLOG" 2>/dev/null; [ "$SLOG" != "$OUTLOG" ] && tail -n 50 "$OUTLOG" 2>/dev/null; echo "LOG_END"
REMOTE
} | run_host > "$OUT" 2>&1
sed -n '/^LOG_BEGIN$/,/^LOG_END$/p' "$OUT" | sed '1d;$d' > "$LOG"
sed '/^LOG_BEGIN$/,/^LOG_END$/d' "$OUT" | sed "s/^/[smoke $HOST] /"
V="$(sed -n 's/^VERDICT //p' "$OUT" | tail -1)"
case "$V" in PASS*) rc=0 ;; UNTESTED*) rc=9 ;; '') say "no verdict from $HOST"; rc=1 ;; *) rc=1 ;; esac

# The port has the last word on its own log (quake2's cvar read-back and exit
# 3, quake3's VALIDATION lines). It gets the log, our rc, and the INFO lines.
if declare -F smoke_verdict >/dev/null && [ $rc -ne 9 ]; then
	smoke_verdict "$LOG" "$rc" "$(grep '^INFO ' "$OUT" | tr '\n' ' ')"; rc=$?
fi
[ $rc -eq 0 ] && say "PASS" || say "result rc=$rc"
exit $rc
