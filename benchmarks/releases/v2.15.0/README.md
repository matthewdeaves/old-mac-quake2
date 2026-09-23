# v2.15.0 release evidence

- `dist/Quake2-OldMac-v2.15.0.dmg`, SHA256
  `47f2cea7383de35ce6892d23df4f83e228c55af114df1b76e13830007653c0bc`,
  packaged on mini-g4 (Tiger G4). Tag `v2.15.0` on 42ba3672, the same build as
  v2.15.0-rc2 (fat stamp `ed84a054…`). With the ad-hoc signatures removed, the
  engine and `ref_gl.so` are byte-identical to rc2's; only the bundle version
  string and its signature differ.
- deps' SDL gate: PASS on rc1 and rc2, 5/5 SDL members (#69).

## Smoke

| host | OS | image | result |
|---|---|---|---|
| yosemite-tiger | 10.4.11 | v2.15.0 | PASS |
| mini-g4 | 10.4.11 | v2.15.0 | PASS |
| g5-panther | 10.3.9 | v2.15.0 | PASS (and rc2 PASS) |
| g5-desktop | 10.5.8 | v2.15.0 | PASS |
| g5-tiger | 10.4.11 | rc2 | PASS, frames checked (#86) |
| mini-sl | 10.6.8 | v2.15.0 | PASS |
| mini-intel2 | 10.7.5 | v2.15.0 | PASS |
| mini-intel | 10.7.5 | v2.15.0 | installed; headless, NOT TESTED |
| imac-2019 | 15.7.9 | v2.15.0 | PASS |
| workstation (M5) | 26.6.2 | v2.15.0 | FAIL (no fps in 45 s during the 8-host parallel run), then PASS in 12 s on retry |

User play-tests on 2026-09-23 (v2.14.0, same engine family): the G5 tower on
Tiger and the G3 on Panther. Measurements: `benchmarks/experiments/2026-09-23-q2-69-baseline/`.
