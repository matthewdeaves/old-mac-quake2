#!/usr/bin/env bash
# bench-compare.sh -- verdict from two or more bench-evidence.sh bundles, so
# agents quote this output instead of writing their own conclusion
# (build-host#104: "a table showing a steady 60 was read as '30 confirmed'"
# and "vsync-quantised 33 ms was read as render cost" were both a human/agent
# eyeballing raw numbers instead of a shared check doing it). CANONICAL copy
# lives in old-mac-build-host, synced byte-identical (drift-rule.md).
#
# usage: scripts/bench-compare.sh --baseline B1 [B2 ...] --candidate C1 [C2 ...]
#   Bx/Cx are bundle directories from bench-evidence.sh (each has stats.txt
#   and stats.unit). Bundles whose own verdict.txt says INVALID are refused.
#
# Exit: 0 always (the verdict is the output, not a pass/fail signal); 2 usage.
set -uo pipefail

usage() { echo "usage: $0 --baseline B1 [B2 ...] --candidate C1 [C2 ...]" >&2; exit 2; }

BASE=(); CAND=(); mode=
for a in "$@"; do
	case "$a" in
		--baseline) mode=base ;;
		--candidate) mode=cand ;;
		*) case "$mode" in
			base) BASE+=("$a") ;;
			cand) CAND+=("$a") ;;
			*) usage ;;
		   esac ;;
	esac
done
[ "${#BASE[@]}" -ge 1 ] && [ "${#CAND[@]}" -ge 1 ] || usage

for b in "${BASE[@]}" "${CAND[@]}"; do
	[ -d "$b" ] || { echo "bench-compare: not a directory: $b" >&2; exit 2; }
	[ -f "$b/stats.txt" ] || { echo "bench-compare: no stats.txt in $b" >&2; exit 2; }
	if [ -f "$b/verdict.txt" ] && [ "$(head -1 "$b/verdict.txt")" = INVALID ]; then
		echo "bench-compare: $b is INVALID, refusing to compare (see its verdict.txt)" >&2
		exit 2
	fi
done

unit() { [ -f "$1/stats.unit" ] && cat "$1/stats.unit" || echo ""; }
U0="$(unit "${BASE[0]}")"
for b in "${BASE[@]}" "${CAND[@]}"; do
	[ "$(unit "$b")" = "$U0" ] || { echo "INCONCLUSIVE: mixed stats.unit across bundles ($U0 vs $(unit "$b"))"; exit 0; }
done
[ -n "$U0" ] || U0=fps

# Drop the first (coldest) round per side when more than one round is given.
# (No nameref: workstation's stock /bin/bash is 3.2, which lacks `local -n`.)
[ "${#BASE[@]}" -gt 1 ] && BASE=("${BASE[@]:1}")
[ "${#CAND[@]}" -gt 1 ] && CAND=("${CAND[@]:1}")

if [ "${#BASE[@]}" -lt 1 ] || [ "${#CAND[@]}" -lt 1 ]; then
	echo "INCONCLUSIVE: fewer than 2 rounds on one side (need a warm round after discarding the cold start)"
	exit 0
fi

stats_of() { local d; for d in "$@"; do cat "$d/stats.txt"; done; }

mean_of() { awk '{s+=$1; n++} END{if(n>0) printf "%.4f", s/n; else print "nan"}'; }
stdev_of() {
	awk '{a[NR]=$1; s+=$1; n++} END{
		if (n<2) { print "0"; exit }
		m=s/n; for(i=1;i<=n;i++) v+=(a[i]-m)^2;
		printf "%.4f", sqrt(v/(n-1))
	}'
}
worst_of() {
	# For fps, worst = min. For ms, worst = max.
	if [ "$U0" = fps ]; then sort -n | head -1; else sort -n | tail -1; fi
}
min_window_of() {
	# Worst 10% of samples (min 1), mean of that slice.
	local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/buildhost-bench-compare.XXXXXX")"
	cat > "$tmp"
	local n; n=$(wc -l < "$tmp" | tr -d ' ')
	local k=$(( n/10 )); [ "$k" -lt 1 ] && k=1
	if [ "$U0" = fps ]; then sort -n "$tmp" | head -"$k" | mean_of
	else sort -n "$tmp" | tail -"$k" | mean_of; fi
	rm -f "$tmp"
}

BASE_STATS="$(stats_of "${BASE[@]}")"
CAND_STATS="$(stats_of "${CAND[@]}")"
BASE_MEAN="$(echo "$BASE_STATS" | mean_of)"
CAND_MEAN="$(echo "$CAND_STATS" | mean_of)"
BASE_SD="$(echo "$BASE_STATS" | stdev_of)"
CAND_SD="$(echo "$CAND_STATS" | stdev_of)"
BASE_WORST="$(echo "$BASE_STATS" | worst_of)"
CAND_WORST="$(echo "$CAND_STATS" | worst_of)"
BASE_WIN="$(echo "$BASE_STATS" | min_window_of)"
CAND_WIN="$(echo "$CAND_STATS" | min_window_of)"

# Interleaving: bundle dirs are named .../<UTC-stamp>; a run of 3+ same-side
# stamps in a row (once merged and sorted) means the rounds weren't ABAB.
INTERLEAVE_NOTE=""
{ for b in "${BASE[@]}"; do echo "B $(basename "$b")"; done
  for b in "${CAND[@]}"; do echo "C $(basename "$b")"; done; } \
	| sort -k2 | awk '{print $1}' | awk '
	{ if ($1==prev) run++; else run=1; if (run>=3) bad=1; prev=$1 }
	END { if (bad) print "not interleaved (3+ same-side rounds in a row)" }' \
	| { read -r n && INTERLEAVE_NOTE="$n"; } || true

NOISE="$BASE_SD"
awk -v a="$CAND_SD" -v b="$NOISE" 'BEGIN{exit !(a>b)}' && NOISE="$CAND_SD"
awk -v n="$NOISE" 'BEGIN{exit !(n==0)}' && NOISE="0.0001"

DIFF="$(awk -v b="$BASE_MEAN" -v c="$CAND_MEAN" 'BEGIN{printf "%.4f", c-b}')"
ABS_DIFF="$(awk -v d="$DIFF" 'BEGIN{printf "%.4f", (d<0?-d:d)}')"

VERDICT="NO-DIFFERENCE"
if [ -n "$INTERLEAVE_NOTE" ]; then
	VERDICT="INCONCLUSIVE"
elif awk -v d="$ABS_DIFF" -v n="$NOISE" 'BEGIN{exit !(d>n)}'; then
	better_is_higher=1; [ "$U0" = ms ] && better_is_higher=0
	if awk -v d="$DIFF" 'BEGIN{exit !(d>0)}'; then
		[ "$better_is_higher" = 1 ] && VERDICT="BETTER" || VERDICT="WORSE"
	else
		[ "$better_is_higher" = 1 ] && VERDICT="WORSE" || VERDICT="BETTER"
	fi
fi

vsync_note() {
	echo "$1" | awk -v u="$U0" '
		{ v = (u=="fps") ? 1000.0/$1 : $1; s+=v; n++ }
		END {
			if (n==0) { print ""; exit }
			m = s/n
			if ((m>15.7 && m<17.7) || (m>32.3 && m<34.3)) print "VSYNC-QUANTISED (~" m "ms)"
			else print ""
		}'
}
BASE_VS="$(vsync_note "$BASE_STATS")"
CAND_VS="$(vsync_note "$CAND_STATS")"

echo "VERDICT: $VERDICT"
echo "unit: $U0  (rounds: baseline=${#BASE[@]} candidate=${#CAND[@]}, cold start discarded)"
printf 'baseline:  mean=%s  worst=%s  min-window(worst10%%)=%s  stdev=%s%s\n' \
	"$BASE_MEAN" "$BASE_WORST" "$BASE_WIN" "$BASE_SD" "${BASE_VS:+  $BASE_VS}"
printf 'candidate: mean=%s  worst=%s  min-window(worst10%%)=%s  stdev=%s%s\n' \
	"$CAND_MEAN" "$CAND_WORST" "$CAND_WIN" "$CAND_SD" "${CAND_VS:+  $CAND_VS}"
echo "diff: $DIFF  (noise band: $NOISE)"
[ -n "$INTERLEAVE_NOTE" ] && echo "note: $INTERLEAVE_NOTE"
exit 0
