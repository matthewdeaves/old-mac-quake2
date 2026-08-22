#!/usr/bin/env bash
# check-frames.sh - assert the rendered PICTURE is still correct on a machine.
#
# usage: scripts/check-frames.sh <machine> [--update]
#        DEMO=demo2.dm2 scripts/check-frames.sh <machine>
#        THRESHOLD=0.04 scripts/check-frames.sh <machine>
#
# WHY THIS EXISTS
# ---------------
# Every other check in this repo passes on a frame that renders wrongly.
# smoke-dmg.sh asserts an fps line exists in qconsole.log; bench.sh measures
# frame rate; tests/test-repo.sh reads shell text. None looks at an image.
#
# That is not theoretical here. MISTAKES.md:400-418, commit 55bfeb8, reverted:
# AltiVec R_LerpVerts rendered monster and viewmodel geometry warped on mini-g4
# and the bench read +4.3% fps, because the broken vertex maths was cheaper than
# the correct maths. A human caught it by looking. The instrumentation scored it
# as a win. Issue #26.
#
# WHY A SEPARATE REFERENCE SET, NOT docs/screenshots/
# ---------------------------------------------------
# docs/screenshots/ is a curated marketing gallery that README.md links, and
# curation deletes exactly the frames a correctness check wants. mini-g4-04.png
# was committed and then deleted in c0fd0bb1 for looking ugly; it is the demo1
# fog-volume transition, which is a rendering feature worth checking. The
# gallery is also regenerated in place by screenshot.sh, so using it as a
# baseline lets the goalposts move silently.
#
# So references live in tests/frames/, complete and never curated, and are
# updated only by --update.
#
# THE NUMBERS BEHIND THE THRESHOLD, measured on mini-g4 2026-08-22, demo1 at
# 1024x768 fullscreen, references downscaled to 256x192, ImageMagick RMSE:
#
#     same binary, two consecutive captures      0          (all 10 frames)
#     three months of legitimate engine change   0.016-0.030
#     world blurred flat                         0.095
#     world posterised to 3 levels               0.069
#     viewmodel region geometrically warped      0.176
#
# The pixels are BIT-IDENTICAL across two runs of one binary, so the noise floor
# is genuinely zero, not merely small: timedemo makes the frame schedule
# deterministic. 0.04 sits 2.5x above the largest legitimate drift seen and 1.7x
# below the smallest simulated break.
#
# HONEST LIMITS. The break figures are SIMULATED — a blurred, posterised or
# warped good frame, not a real broken render. They bound the shape of the two
# failures we have actually seen (quake3's flat untextured world, our warped
# models), not their magnitude. And 256x192 catches STRUCTURAL breaks; a small
# localised artefact can fall under the threshold. Both real incidents were
# structural: every alias model, or every world surface.
set -euo pipefail

TARGET="${1:?usage: $0 <machine> [--update]}"
MODE="${2:-check}"
THRESHOLD="${THRESHOLD:-0.04}"
REF_W=256
REF_H=192

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${DEMO:-demo1.dm2}"
DEMO_BASE="${DEMO%.dm2}"
if [ "$DEMO_BASE" = "demo1" ]; then TAG="$TARGET"; else TAG="${TARGET}-${DEMO_BASE}"; fi
REF_DIR="$REPO_ROOT/tests/frames"

# ImageMagick 7 ships `magick`; 6 ships `compare`. Both can do this. No new
# dependency: screenshot.sh already needs one of these to make PNGs at all.
if   command -v magick  >/dev/null 2>&1; then IM="magick"
elif command -v compare >/dev/null 2>&1; then IM=""
else
	echo "check-frames: needs ImageMagick (magick or compare) on this workstation" >&2
	exit 2
fi
im_compare() { if [ -n "$IM" ]; then magick compare "$@"; else compare "$@"; fi; }
im_convert() { if [ -n "$IM" ]; then magick "$@"; else convert "$@"; fi; }

# No bench-lock re-exec here on purpose. The capture is screenshot.sh, which
# claims the machine itself under pick-bench-host.sh --run and releases however
# it ends. Claiming again around it would be a nested acquire on a host we
# already hold, which the bare-mkdir lock cannot do. See pick-bench-host.sh
# cmd_run and its RETRO_BENCH_LOCK export.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/checkframes.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

echo "[check-frames] capturing $TAG from $TARGET"
SHOT_DIR="$TMPD/shots" DEMO="$DEMO" "$REPO_ROOT/scripts/screenshot.sh" "$TARGET" >"$TMPD/capture.log" 2>&1 || {
	echo "[check-frames] FAIL: capture failed. Last 20 lines:" >&2
	tail -20 "$TMPD/capture.log" >&2
	exit 1
}

SHOTS=$(ls "$TMPD/shots/${TAG}-"[0-9][0-9].png 2>/dev/null | sort || true)
NSHOTS=$(printf '%s\n' "$SHOTS" | grep -c . || true)
if [ "$NSHOTS" -eq 0 ]; then
	echo "[check-frames] FAIL: capture produced no PNGs. Last 20 lines:" >&2
	tail -20 "$TMPD/capture.log" >&2
	exit 1
fi
echo "[check-frames] captured $NSHOTS frames"

if [ "$MODE" = "--update" ]; then
	mkdir -p "$REF_DIR"
	rm -f "$REF_DIR/${TAG}-"[0-9][0-9].png
	n=0
	for s in $SHOTS; do
		out="$REF_DIR/$(basename "$s")"
		im_convert "$s" -resize "${REF_W}x${REF_H}!" -depth 8 -strip "$out"
		n=$((n+1))
	done
	echo "[check-frames] wrote $n references to tests/frames/"
	echo "  These assert the picture is CORRECT. Look at them before committing:"
	echo "  the check can only hold the picture where you last left it."
	exit 0
fi

if [ ! -d "$REF_DIR" ]; then
	echo "[check-frames] FAIL: no tests/frames/ — run '$0 $TARGET --update' once, and LOOK at the result" >&2
	exit 1
fi

FAIL=0
MISSING=0
CHECKED=0
printf '  %-22s %-12s %s\n' frame RMSE verdict
for s in $SHOTS; do
	base="$(basename "$s")"
	ref="$REF_DIR/$base"
	# A missing reference is a FAILURE, not a skip. The gallery lost
	# mini-g4-04.png to curation and nobody noticed for three months; a check
	# that silently passes over absent references repeats that quietly.
	if [ ! -f "$ref" ]; then
		printf '  %-22s %-12s %s\n' "$base" "-" "NO REFERENCE"
		MISSING=$((MISSING+1)); FAIL=1; continue
	fi
	im_convert "$s" -resize "${REF_W}x${REF_H}!" -depth 8 -strip "$TMPD/cur.png"
	# `|| true` is load-bearing, not defensive noise. ImageMagick's compare exits
	# 1 whenever the images DIFFER, which is the case this whole script exists to
	# report. Without it, `set -e` kills the run at the first changed frame, and
	# the output then looks like a short clean pass rather than a failure --
	# measured on quicksilver 2026-08-22 while testing the failing direction.
	rmse="$(im_compare -metric RMSE "$ref" "$TMPD/cur.png" null: 2>&1 | sed 's/.*(\(.*\))/\1/' || true)"
	case "$rmse" in
		''|*[!0-9.e+-]*)
			printf '  %-22s %-12s %s\n' "$base" "$rmse" "COMPARE FAILED"
			FAIL=1; continue ;;
	esac
	CHECKED=$((CHECKED+1))
	if awk -v a="$rmse" -v b="$THRESHOLD" 'BEGIN{exit !(a>b)}'; then
		printf '  %-22s %-12s %s\n' "$base" "$rmse" "CHANGED"
		FAIL=1
	else
		printf '  %-22s %-12s %s\n' "$base" "$rmse" "ok"
	fi
done

echo
if [ "$FAIL" -eq 0 ]; then
	echo "[check-frames] PASS — $CHECKED frames match their reference within $THRESHOLD"
	exit 0
fi
echo "[check-frames] FAIL — the picture changed on $TARGET (threshold $THRESHOLD)" >&2
[ "$MISSING" -gt 0 ] && echo "  $MISSING frame(s) had no reference at all." >&2
cat >&2 <<'HINT'
  This is not automatically a bug: a deliberate visual feature changes the
  picture too. Look at the frames before deciding. If the new picture is
  correct, re-baseline with --update and commit the references with the change
  that caused them.
HINT
exit 1
