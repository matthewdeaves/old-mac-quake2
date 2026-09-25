#!/usr/bin/env bash
# bench-evidence.sh -- run one bench pass through a port's adapter and capture
# an evidence bundle, so "invalid measurement read as valid" (build-host#104:
# alephone#42's paused/unfocused run, quake3's stale-dev-deploy tearing,
# quake3#67's `build | tail` hiding a failed build, alephone#42's steady-60
# table read as "30 confirmed", keeperfx#14's vsync-quantised 33 ms) becomes a
# mechanical check instead of a one-off fix per port. CANONICAL copy lives in
# old-mac-build-host, synced byte-identical into each port; never edit a
# port's copy (drift-rule.md). Contract: docs/bench-evidence.md.
#
# usage: scripts/bench-evidence.sh <host> <round-label> [--requested k=v,...]
#
# Reads scripts/bench-adapter.sh (port-owned, next to this script once
# synced; override with BENCH_ADAPTER=<path>) for PORT, INSTALL_BIN and the
# three bench_launch/bench_liveness/bench_effective_config functions.
#
# Exit: 0 valid, 1 invalid (see verdict.txt in the bundle), 2 usage/config.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-}"; ROUND="${2:-}"
if [ -z "$HOST" ] || [ -z "$ROUND" ] || [ "$HOST" = -h ]; then
	echo "usage: $0 <host> <round-label> [--requested k=v,k2=v2]" >&2
	exit 2
fi
shift 2
REQUESTED=""
while [ $# -gt 0 ]; do
	case "$1" in
		--requested) REQUESTED="${2:-}"; shift 2 ;;
		*) echo "bench-evidence: unknown arg $1" >&2; exit 2 ;;
	esac
done

ADAPTER="${BENCH_ADAPTER:-$SELF_DIR/bench-adapter.sh}"
[ -r "$ADAPTER" ] || { echo "bench-evidence: no adapter at $ADAPTER (see docs/bench-evidence.md)" >&2; exit 2; }
PORT=; INSTALL_BIN=
# shellcheck source=/dev/null
. "$ADAPTER"
for f in bench_launch bench_liveness bench_effective_config; do
	command -v "$f" >/dev/null 2>&1 || { echo "bench-evidence: adapter must define $f()" >&2; exit 2; }
done
[ -n "$PORT" ] && [ -n "$INSTALL_BIN" ] || { echo "bench-evidence: adapter must set PORT and INSTALL_BIN" >&2; exit 2; }

# Hardware is claimed, never assumed free (cross-repo-workflow.md).
_PICK="$SELF_DIR/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "$PORT bench-evidence $ROUND" -- "$0" "$HOST" "$ROUND" ${REQUESTED:+--requested "$REQUESTED"}
fi

say() { echo "[bench-evidence $HOST/$ROUND] $*"; }

if [ "$HOST" = workstation ]; then
	run_host() { bash -s; }
	sh_host() { bash -c "$1"; }
else
	run_host() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" bash -s; }
	sh_host() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$1"; }
fi

# PID suffix: macOS `date` has no sub-second resolution, and #109's own
# repro (imac-2019, ~1s demo runs) means two real back-to-back rounds can
# land in the same wall-clock second. Without a disambiguator, the second
# round's mkdir -p would silently reuse the first round's directory and mix
# its files with the new run's (found while testing the #109 frame-capture
# fix above: two fast fixture rounds collided this way). The suffix sorts
# after the timestamp, so bench-compare.sh's interleaving check (sorts by
# directory name) is unaffected.
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
EVROOT="$HOME/oldmac/evidence/$PORT/$STAMP"
mkdir -p "$EVROOT"
say "bundle: $EVROOT"

REASONS=()
NOTCHECKED=()

# --- artefact + installed hash (build-host#40: never Apple's lipo on PPC) ---
# #109: a hash that could not be compared is now INVALID, not "not checked"
# -- the old NOTCHECKED path let a bundle with no BENCH_ARTEFACT at all read
# VALID, which defeats the point of this file (an agent quoting verdict.txt
# should never see VALID over an artefact nobody actually compared).
# #107: INSTALL_BIN may be an absolute path (the contract doc always said
# so); only prepend $HOME when it is NOT one -- the old code always did,
# which collapsed an absolute path like /Applications/Quake3/... into
# $HOME/Applications/Quake3/..., silently reading nothing.
# #110: shasum (and any SHA-256-capable openssl) is missing entirely on
# PowerPC Tiger/Leopard bench hosts, so hashing has to happen on the
# workstation instead, over `ssh ... cat`, which every host can serve
# regardless of its own toolchain age.
ARTEFACT="${BENCH_ARTEFACT:-}"
ARTEFACT_SHA=""; ARTEFACT_LIPO=""
if [ -n "$ARTEFACT" ] && [ -f "$ARTEFACT" ]; then
	ARTEFACT_SHA="$(shasum -a 256 "$ARTEFACT" | awk '{print $1}')"
	if command -v python3 >/dev/null 2>&1 && [ -x "$SELF_DIR/fat-slices.py" ]; then
		ARTEFACT_LIPO="$(python3 "$SELF_DIR/fat-slices.py" "$ARTEFACT" 2>/dev/null | tr '\n' ';')"
	fi
fi

case "$INSTALL_BIN" in
	/*) REMOTE_CAT="cat \"$INSTALL_BIN\" 2>/dev/null" ;;
	*)  REMOTE_CAT="cat \"\$HOME/$INSTALL_BIN\" 2>/dev/null" ;;
esac
INSTALLED_TMP="$(mktemp "${TMPDIR:-/tmp}/buildhost-bench-evidence-installed.XXXXXX")"
if [ "$HOST" = workstation ]; then
	bash -c "$REMOTE_CAT" > "$INSTALLED_TMP" 2>/dev/null
else
	ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$REMOTE_CAT" > "$INSTALLED_TMP" 2>/dev/null
fi
INSTALLED_SHA=""
[ -s "$INSTALLED_TMP" ] && INSTALLED_SHA="$(shasum -a 256 "$INSTALLED_TMP" | awk '{print $1}')"
rm -f "$INSTALLED_TMP"

if [ -n "$ARTEFACT_SHA" ] && [ -n "$INSTALLED_SHA" ]; then
	[ "$ARTEFACT_SHA" = "$INSTALLED_SHA" ] || REASONS+=("installed hash $INSTALLED_SHA != artefact hash $ARTEFACT_SHA")
elif [ -z "$ARTEFACT_SHA" ]; then
	REASONS+=("artefact hash not checked: BENCH_ARTEFACT not set or not readable")
else
	REASONS+=("artefact hash not checked: installed binary unreadable on $HOST ($INSTALL_BIN)")
fi

# --- host identity ---
HOST_INFO="$(sh_host 'sysctl -n hw.model 2>/dev/null; sw_vers -productVersion 2>/dev/null; sw_vers -buildVersion 2>/dev/null')"
HOST_MODEL="$(echo "$HOST_INFO" | sed -n 1p)"
HOST_OS="$(echo "$HOST_INFO" | sed -n 2p)"
HOST_BUILD="$(echo "$HOST_INFO" | sed -n 3p)"

# --- requested settings, if any ---
if [ -n "$REQUESTED" ]; then
	echo "$REQUESTED" | tr ',' '\n' > "$EVROOT/requested.txt"
else
	NOTCHECKED+=("effective vs requested settings: no --requested given")
fi

# --- launch, via the adapter ---
LAUNCH_OUT="$(bench_launch "$HOST" "$ROUND" "$EVROOT" 2>"$EVROOT/launch-stderr.txt")"
EXIT_CODE="$(echo "$LAUNCH_OUT" | sed -n 's/^EXIT=//p' | tail -1)"
LPID="$(echo "$LAUNCH_OUT" | sed -n 's/^PID=//p' | tail -1)"
[ -n "$EXIT_CODE" ] || EXIT_CODE="unknown"

# #108: a failed launch must not verdict VALID just because the hash/
# liveness/frame checks around it all happened to look fine. EXIT_CODE is
# recorded in meta.json either way; this is the check that actually acts on
# it, plus the stats.txt the contract requires bench_launch to have written
# by the time it returns (docs/bench-evidence.md).
case "$EXIT_CODE" in
	0) ;;
	unknown) REASONS+=("bench_launch did not report EXIT=<code> (adapter contract violation)") ;;
	*[!0-9]*) REASONS+=("bench_launch reported a non-numeric EXIT=$EXIT_CODE") ;;
	*) REASONS+=("bench_launch exited $EXIT_CODE") ;;
esac
[ -s "$EVROOT/stats.txt" ] || REASONS+=("stats.txt missing or empty after bench_launch returned")

# --- frame capture, only meaningful while the adapter left the process
# running (build-host#109, manager's fleet-wide repro 2026-09-25). A
# synchronous adapter's bench_launch already blocks through the whole run
# and returns only once the game has quit, so a "before launch" / "after
# return" pair of captures both show the idle desktop -- they only
# differed by luck (the menu-bar clock ticking over mid-run), which failed
# this check on most otherwise-fully-valid bundles for any class whose
# whole run fits inside one minute (confirmed on imac-2019, mini-intel and
# imac-g5). Capture is only attempted now, AFTER bench_launch has returned
# AND only when it left a live PID: two frames a few seconds apart while
# the game is CONFIRMED running, the same shape as the liveness check right
# below rather than idle-vs-running. A synchronous adapter gets "not
# checked" here, same as liveness already does for it -- there is no live
# frame available to capture once bench_launch has already returned with
# the game gone, and reporting one anyway (as the old before/after pair
# did) risks a false INVALID on a fully valid run, which is worse than not
# checking at all.
FRAME1=""
if [ -n "$LPID" ] && sh_host 'command -v screencapture >/dev/null 2>&1'; then
	if [ "$HOST" = workstation ]; then
		screencapture -x "$EVROOT/frame-first.png" 2>/dev/null && FRAME1=yes
	else
		ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
			"screencapture -x /tmp/buildhost-bench-evidence-frame1.png" 2>/dev/null \
			&& scp -q -o BatchMode=yes "$HOST:/tmp/buildhost-bench-evidence-frame1.png" "$EVROOT/frame-first.png" 2>/dev/null \
			&& FRAME1=yes
	fi
fi
if [ -z "$FRAME1" ]; then
	if [ -z "$LPID" ]; then
		NOTCHECKED+=("frame capture: adapter is synchronous (bench_launch already returned with the game quit) -- no live frame available")
	else
		NOTCHECKED+=("frame capture: not available on $HOST")
	fi
fi

# --- liveness, only if the adapter left the process running ---
if [ -n "$LPID" ]; then
	L1="$(bench_liveness "$HOST" 2>/dev/null)"
	sleep 3
	L2="$(bench_liveness "$HOST" 2>/dev/null)"
	printf '%s\t%s\n%s\t%s\n' "$(date +%s)" "$L1" "$(date +%s)" "$L2" > "$EVROOT/liveness.txt"
	if [ -n "$L1" ] && [ "$L1" = "$L2" ]; then
		REASONS+=("liveness counter did not advance ($L1 == $L2) -- paused, frozen or unfocused")
	fi
else
	NOTCHECKED+=("liveness: bench_launch left no PID (synchronous adapter)")
fi

# --- last frame ---
if [ -n "$FRAME1" ]; then
	if [ "$HOST" = workstation ]; then
		screencapture -x "$EVROOT/frame-last.png" 2>/dev/null
	else
		ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
			"screencapture -x /tmp/buildhost-bench-evidence-frame2.png" 2>/dev/null \
			&& scp -q -o BatchMode=yes "$HOST:/tmp/buildhost-bench-evidence-frame2.png" "$EVROOT/frame-last.png" 2>/dev/null
	fi
	if [ -f "$EVROOT/frame-first.png" ] && [ -f "$EVROOT/frame-last.png" ]; then
		H1="$(shasum -a 256 "$EVROOT/frame-first.png" | awk '{print $1}')"
		H2="$(shasum -a 256 "$EVROOT/frame-last.png" | awk '{print $1}')"
		[ "$H1" != "$H2" ] || REASONS+=("first and last captured frames are byte-identical")
	fi
fi

bench_effective_config "$HOST" > "$EVROOT/effective.txt" 2>/dev/null
if [ -s "$EVROOT/requested.txt" ] && [ -s "$EVROOT/effective.txt" ]; then
	while IFS='=' read -r k v; do
		[ -n "$k" ] || continue
		ev="$(awk -F= -v k="$k" '$1==k{print substr($0,index($0,"=")+1)}' "$EVROOT/effective.txt")"
		[ -z "$ev" ] && continue
		[ "$ev" = "$v" ] || REASONS+=("effective $k=$ev != requested $k=$v")
	done < "$EVROOT/requested.txt"
fi

# --- meta.json (python3's json module, not printf %q -- %q shell-quotes,
# which leaves plain strings unquoted and commas backslash-escaped, producing
# invalid JSON) ---
COMMIT="$(git -C "$SELF_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)"
python3 - "$EVROOT/meta.json" \
	"$PORT" "$ROUND" "$COMMIT" "${ARTEFACT_SHA:-}" "${ARTEFACT_LIPO:-}" \
	"${INSTALLED_SHA:-}" "$HOST" "${HOST_MODEL:-unknown}" "${HOST_OS:-unknown}" \
	"${HOST_BUILD:-unknown}" "$EXIT_CODE" "$STAMP" <<'PYEOF'
import json, sys
out, port, round_, commit, art_sha, art_lipo, inst_sha, host, model, os_ver, build, exitc, stamp = sys.argv[1:]
data = {
	"port": port, "round": round_, "commit": commit,
	"artefact_sha256": art_sha or None, "artefact_lipo": art_lipo or None,
	"installed_sha256": inst_sha or None, "host": host, "host_model": model,
	"host_os": os_ver, "host_build": build, "exit_code": exitc, "started_utc": stamp,
}
with open(out, "w") as f:
	json.dump(data, f, indent=2)
	f.write("\n")
PYEOF

# --- verdict ---
if [ "${#REASONS[@]}" -eq 0 ]; then
	echo "VALID" > "$EVROOT/verdict.txt"
	RC=0
else
	{ echo "INVALID"; printf '%s\n' "${REASONS[@]}"; } > "$EVROOT/verdict.txt"
	RC=1
fi
if [ "${#NOTCHECKED[@]}" -gt 0 ]; then
	{ echo; echo "not checked:"; printf '  - %s\n' "${NOTCHECKED[@]}"; } >> "$EVROOT/verdict.txt"
fi

say "$(head -1 "$EVROOT/verdict.txt")"
[ "$RC" -eq 0 ] || say "$(tail -n +2 "$EVROOT/verdict.txt" | grep -v '^$' | grep -v '^not checked:' | grep -v '^  -')"
echo "$EVROOT"
exit "$RC"
