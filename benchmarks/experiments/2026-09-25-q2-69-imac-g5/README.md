# #69 imac-g5 baseline, 2026-09-25

imac-g5 (PowerMac8,2, ATI Radeon 9600 128MB, native 1440x900) was off for
every prior #69 pass; user booted it this session. Distinct physical unit
from g5-tiger/g5-panther/g5-desktop (already baselined) and from #66's imac-g5
GL-init hang, which is closed.

**Install**: was stale at v2.12.0 (engine md5 `2f7874dd…`). Deployed current
v2.15.0 (DMG sha256 `47f2cea7…`, matches the promoted GitHub asset digest
exactly). New engine md5 `f740a75d2434bc24a7233dc4c7be0f25` — matches the
md5 already recorded against v2.15.0 on g5-desktop, confirming this is the
same shipped build. `smoke-dmg.sh imac-g5` PASS; live readback confirmed
bloom 0, MSAA 2, native 1440x900 desktop-fullscreen, vsync 1 (both smoke
passes, before and unaffected by the bench arms below).

**Bench**, `bench.sh imac-g5 demo1 1440x900`, vsync off (bench driver), 3
runs/arm:

| Arm | fps (3 runs) | Median |
|---|---|---:|
| Shipped (A1) | 46.9, 46.4, 46.8 | 46.60 |
| `+set viewsize 40` | 87.6, 87.8, 87.8 | 87.80 |
| Shipped (A2) | 46.9, 46.9, 46.9 | 46.90 |

**Verdict: fill-bound.** Shrinking the 3D view to 40% nearly doubles fps
(46.6/46.9 → 87.8), the same pattern as every other G4/G5-class box in this
ticket's baseline pass. A1/A2 agree within 0.3 fps, so the shipped number is
stable. 46.6-46.9 fps clears the ~40 fps G4/G5-class floor with real
headroom, same as g5-tiger's 50.7-50.8 and g5-desktop (no separate fps pass
run there, effects-focused instead). No optimization hypothesis tried this
pass — reporting the baseline as asked; a fill-rate lever (MSAA/bloom cost,
same family as g5-tiger's #86/#87 findings) would be the next thing to try
here specifically, not attempted yet.

Raw logs in `raw/`. Note: A1's per-run demo logs were overwritten by A2 (same
commit/target/demo/res/EXTRA slug — bench.sh names raw logs by that tuple,
and A1/A2 share it since neither has an EXTRA). Both medians are preserved in
`benchmarks/results.csv`; only A2's per-frame log survives on disk under
`run1/2/3.log`, A1's aggregate is CSV-only.

Mid-bench, `old-mac-halflife-81` claimed imac-g5 for a v1.9.20 install smoke
routed by buildhost (build-host#100) right as I released between arms;
coordinated by mail, machine handed back after the A2 confirmation run.
