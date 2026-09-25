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

## Quality-trade follow-up: keep shipped, user overrides the hypothesis

Manager asked (46.6 fps on a 60Hz panel could mean uneven 16/33ms frames) to
test two same-session candidates against shipped and adopt one if it holds a
steady 60 for a quality loss judged minor: (a) the most fill-heavy effect
off, (b) one resolution step down.

- **(a) `gl_msaa_samples 0`** (bloom is already off in the shipped profile;
  MSAA is this cfg's own documented biggest fill-rate lever —
  `autoexec-imac-g5.cfg:124-131`): demo1 @ 1440x900, 3 runs, **100.0, 100.0,
  100.0 fps**, median 100.00. Clears 60 with room. Raw logs in `raw/`.
- **(b) resolution step down**: not run. ADR 0008's guard applies —
  fullscreen at any non-native resolution on this exact R300/Leopard combo
  hard-hangs the whole OS (physical power button only to recover), and
  `bench.sh` itself refuses it outright unless `G5_WINDOWED=1` (windowed,
  safe at any res). Moot once (a) already clears 60 and the decision below
  went the other way regardless.

**Decision: kept the shipped profile, MSAA candidate not adopted.** Before
running (b), the user played the current build on this exact imac-g5 and
reported unprompted: *"from what i was seeing 46 fps on a 60 Hz screen was
not an issue to my eye.. and i want the game to look the best it possibly
can on g5 machines they can handle it!"* That's a direct real-world verdict
on the actual question the manager's hypothesis was a proxy for (does 46 fps
read badly on this panel), and it also restates this project's standing
policy (`docs/adr/0009`: floors are the raw bench number, visuals over
framerate above it — 46.6-46.9 fps clears the ~40 fps G4/G5 floor with
headroom). No default changed. The 100 fps MSAA-off number is recorded for
reference only, not shipped.
