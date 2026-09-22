#!/usr/bin/env bash
# Analysis only; arguments are the two native-resolution capture directories.
set -euo pipefail
baseline=${1:?baseline directory}
candidate=${2:?candidate directory}
echo 'frame,native_normalized_rmse'
for frame in 00 01 02 03 04 05 06 07 08 09; do
 status=0
 metric=$(magick compare -metric RMSE "$baseline/mini-sl-$frame.png" "$candidate/mini-sl-$frame.png" null: 2>&1) || status=$?
 if [ "$status" -gt 1 ]; then echo "$metric" >&2; exit "$status"; fi
 value=${metric##*\(}
 value=${value%\)}
 printf '%s,%s\n' "$frame" "$value"
done
