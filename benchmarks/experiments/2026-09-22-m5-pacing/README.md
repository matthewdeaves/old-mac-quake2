# M5 periodic gameplay pauses

User report: smooth movement interrupted by a short freeze roughly every
second on Apple M5/macOS 26.6.2. G3 gameplay remained smooth.

## Diagnosis

The installed six-slice engine was MD5
`59137715ba3aa270e744d0a410b892a2`, renderer
`52ec8f0e7f2ccacdea75ca8e32b44f66`. Apple Silicon profile, full view,
desktop fullscreen, bloom, projected shadows, 4x MSAA, sound initialization
enabled, game volume 0.7, vsync 1, cap 250. No graphics reduction.

`trace.c` temporarily interposes SDL swap and audio-lock calls, records
monotonic timestamps in memory, and periodically writes a CSV. `run.sh` is
the archived, session-specific diagnostic driver, not a portable benchmark.
It runs under the shared workstation picker and restores the user's config.
It starts normal-speed demo playback; the user also interacted with the game
and started base1 during the investigation. These traces are not matched-camera
or equal-duration throughput comparisons. They include map loads and sampling
overhead. Do not interpret their maxima as steady-state gameplay latency.

In `sample-baseline.txt`, 784 main-thread samples are under SDL event polling.
Of those, 746 are under application activation and 745 reach a WindowServer
IPC wait. The callback is `SDLMain windowDidChange:`. It was subscribed to
`NSWindowDidUpdateNotification`, yet also marked views dirty and unconditionally
activated the app, repeating window setup during ordinary redraws.

The temporary `window-test.m` filter suppresses only that update notification.
Key/main-window notifications still run the original setup. The filtered sample
no longer contains the activation stack. The user independently reported that
the filtered game ran smoothly during this test.

`stats.py` excludes the first five seconds and reports:

| Trace | Frames | Interval median | p95 | p99 | Audio-lock maximum |
|---|---:|---:|---:|---:|---:|
| Original | 1043 | 16.685 ms | 33.530 ms | 149.495 ms | 0.009 ms |
| Filtered | 868 | 16.677 ms | 17.749 ms | 33.424 ms | 0.018 ms |

Both traces include an approximately two-second load gap. The filtered trace
also has a 101 ms outlier. This is evidence for removing a recurring stall,
not a claim that every possible hitch is eliminated. Audio-lock contention
does not explain these captured long pauses.

## Permanent change

Remove the recurring update-notification subscription from SDLMain.m. Keep
both key/main-window subscriptions and their initial surface setup unchanged.
This repairs event handling, not a machine quality setting; no new cvar or
graphics downgrade is introduced. A self-testing repository invariant rejects
reintroduction of the update subscription.

An additional normal-speed demo run of the original installed engine without
the sampling profiler was smooth: `baseline-repeat.csv`, p99 17.765 ms and
no intervals over 25 ms in the first captured 941 post-warmup frames. Thus the
stall is not deterministic in every run. Window interaction/activation state
and the user's live gameplay differ from unattended demo playback. This repeat
does not support claiming a universal frame-time improvement; the direct
activation stacks and the live filtered test justify removing the unnecessary
recurring callback.

## Installed acceptance

Code commit `c04ad992eb5f841819f1f0bf79f331e7d58f4c58`, Actions
35754601185 SUCCESS. Repository invariants pass. Full six-slice build passes,
source stamp `92213e21568bda62b2f7acca69065c789607d85c96d5b6598cc142b7929ab6ff`.
All four installed runtime products match the built candidate, see install.log.
Engine MD5 `bd3bb1a24e431696678d62d548f053c9`.
The M5 install is `/Applications/Quake2/Quake2.app`; previous install retained
at `/Users/matt/oldmac/quake2/rollbacks/Quake2.rollback-20260922T163331Z-59137715ba3a`.
No injected libraries are part of the installed app. G3 was not updated here.

Permanent build, first level base1 with rotating camera, sound enabled, vsync1,
full view and unchanged graphics profile: 986 post-warmup frames, median
16.674 ms, p95 17.702 ms, p99 32.183 ms, maximum 34.354 ms, no frames over
50 ms. Timing-only interposer, no window-filter library or sampling profiler.
Screenshot inspected: full scene, weapon, lighting and bloom rendered without
the reduced-view border artifact. Bloom stage GL errors all zero.

The user confirmed smooth play again and explicitly asked us to listen and
stop further testing. No final three-run timedemo comparison was performed;
the baseline-only 112.70 fps result is not evidence of a throughput gain.
This change fixes recurring window-update work; it does not claim to remove
every possible frame-time outlier. Temporary gameplay cfg removed after the
bounded run. Manual M5 sound remains enabled; no graphics knobs changed.
