# Mistakes log — things we tried that were bad

Append-only record of changes that landed in tree (or were attempted)
and turned out to be wrong, harmful, or otherwise misjudged. Each
entry exists so future rounds don't re-litigate the same idea on
incomplete information.

Format: date, what we tried, what went wrong, what the fix was, what
we learned. Newest at the top.

See `~/quakespasm/MISTAKES.md` for cross-applicable lessons from the
sister project — especially anything about benchmark concurrency
(don't run g3+g4 builds in parallel; don't run bench.sh legs
concurrently from one shell), and SDL framework dyld install_name
quirks.

---

## 2026-05-19 — `gl_dynamic 1` on GeForce2 MX (sawtooth) is a catastrophic regression

What we tried: as part of the "sawtooth visual unlock" round (the box has
50-60% fps headroom over the 60 fps playability floor), flipped the
autoexec from `gl_dynamic 0` to `gl_dynamic 1` along with several other
visual unlocks (`gl_picmip 0`, `gl_skymip 0`, `gl_round_down 0`,
`gl_texturemode GL_LINEAR_MIPMAP_LINEAR`, `gl_shadows 1`).

What went wrong: 83 fps → 15 fps demo1 1024×768. 95 fps → 15 fps at 640.
~80% regression — well below the 60 fps floor. Reverted to `gl_dynamic 0`
and the other changes were retained; FPS settled at 70/78 (~15-18% under
baseline, still comfortably above the floor).

What we learned: the **GeForce2 MX cannot afford per-frame lightmap
rebuild for dlight-touched surfaces**, regardless of fps headroom in
other dimensions. The chip's fixed-function lightmap-reblend path is
prohibitive: a single rocket light or muzzle flash forces a `glTexSubImage2D`
upload + a re-blend pass per affected surface, and demo1 has enough
dlights to stay in that path most of the frame. Cost is bandwidth on the
AGP bus, not fillrate. The original autoexec comment ("GeForce2 MX still
pays the lightmap-reblend cost; skip") was load-bearing. Don't try
`gl_dynamic 1` on sawtooth again without a fundamentally different
dlight code path (e.g. a subrect upload that uploads only the touched
columns — would help here even though it didn't help G3 where dlights
are already off).

Bench data: see commit immediately following this entry.

---

## 2026-05-19 — Lightmap subrect doesn't unlock dlights on sawtooth either (try-2)

What we tried: after landing the lightmap subrect upload (Phase B #1, commit
937a870), retried `gl_dynamic 1` on sawtooth — the QS subrect commit
predicted ~4-12% wins on AGP-bound dynamic uploads, and the GF2 MX is one
of those candidate cards. Theory: less data per `glTexSubImage2D` =
breathing room on the 1999 AGP bus.

What went wrong: 15.25 fps demo1 1024×768. AND 15.3 fps demo1 640×480 —
identical at half the pixel count, which is the smoking gun: the
bottleneck is NOT GPU/AGP. The cost is CPU-side `R_BuildLightMap` +
`R_AddDynamicLights` per-luxel float math, which runs once per
dlight-touched surface per frame regardless of resolution. The subrect
optimization helps the GPU TRANSFER, not the CPU REBUILD. Wrong knob.

What we learned: when a regression scales the same at different
resolutions, it is CPU-bound, full stop. A bandwidth optimization can't
fix CPU. The actionable fix for `gl_dynamic 1` on a 500 MHz G4 is one
of: (a) AltiVec the `R_BuildLightMap` scaled-add inner loop + the
`R_AddDynamicLights` per-luxel branch; (b) ship `gl_flashblend 1`
instead (billboard halos, no per-surface relight at all).

Bench: 937a870_sawtooth_demo1_1024x768_run{1,2,3}.log + the 640x480
single-run probe. See results.csv row dated 2026-05-19T19:27:35Z.

Resolution: sawtooth ships with `gl_flashblend 1` (try-3, billboard
halos visible at ~69 fps demo1 1024) — the cheap-visual path that
maintains 60+ fps floor while still showing dlight presence.

---

## 2026-05-19 — Lightmap subrect upload port is gated to the wrong machine

What we tried (or rather, was on the candidate list): port QS commit
294b8d03's `gl_lightmap_subrect` from `~/quakespasm/Quake/r_brush.c` to
yquake2 5.11's `src/refresh/r_lightmap.c:71`. QS audit predicted +4.2% on
demo1 1024 — enough to lift yosemite over the 20 fps floor.

What went wrong (before any code change): the QS audit overlooked that
yosemite's autoexec sets `gl_dynamic 0`, which gates the entire
`R_RenderLightmappedPoly` dynamic path in 5.11 (`r_surf.c:279/429/651`).
With dlights off, `LM_UploadBlock(true)` never fires — the subrect
optimization has nothing to optimize on yosemite.

What we learned: **per-machine autoexec settings change which code paths
are hot.** Phase B cherry-pick priorities derived from QS bench data
need to be re-checked against the corresponding Q2 autoexec before
deciding which machines benefit. The subrect upload IS still on the
table for the gl_dynamic=1 cohort (quicksilver / mini-g4 / mini-intel /
imac-2019) — and per the dlight regression above on sawtooth, it might
even unlock dlights on sawtooth.

---

*(older entries below)*


