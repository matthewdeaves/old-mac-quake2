# Resume here — 2026-09-08

## PAUSED BY USER — supersedes running-test notes below

User requested commit and pause. All active benchmark processes were stopped;
do not resume work until asked. Session 92563 is stopped, not pending.

CRITICAL discovery at pause: the latest +exec q2-lock-off.cfg/on.cfg tests
are INVALID. Raw logs say "couldn't exec q2". Cbuf_AddLateCommands in
common/cmdparser.c terminates commands at ANY '-' character, including
inside filenames. Resume using underscore-only names (q2_lock_off.cfg etc.)
and verify the execution line before accepting FPS. Do NOT fix the parser
as part of this benchmark task without considering scope and regressions.
Invalid evidence is preserved in invalid-lock-test/.

The earlier +exec refactor-sort-test.cfg screenshot checks have the SAME
filename problem. Their image comparisons passed but do not verify the
requested config; retract those as proof of the sort/combined configurations.
Re-run with underscore-only config names. Direct +set timedemos (including
the 40.85 -> 41.20 comparison) remain valid. Earlier all-three +set frame
checks from before these +exec experiments remain separate valid evidence.

G3 has recovered, and its isolation results below are complete. Locking
performance is UNMEASURED; gl_mesh_lockarrays remains default off.

User is switching to a cheaper model. Continue authorized refactor improvement
and hardware benchmarking. NO RELEASE, packaging, tags, commits or publication
until user says. Bloom remains broken (black world) on local Apple Silicon;
force it off for every test. Preserve all unrelated worktree changes, especially
MacOSX/SDL.framework/Versions/A/SDL. Do not reset the tree.

Read this directory's README.md for completed sorting work, then project
rules/commands and hardware lock instructions. Use scripts/pick-bench-host.sh
locks; do not work around busy hosts. No subagents requested.

## Newest code/build

The three original switches default off. Added gl_worldsort (default 1)
to separate retained geometry from sorting; tested in README.md.
After that, added gl_mesh_lockarrays (default 0), which optionally uses
compiled-array locks for retained world, indexed alias and shadow draws.
World locks skip VBOs and spans >= WORLD_INDEX_BATCH (16384 vertices).
Both lock and unlock function pointers are required. Test harness checks
referenced index bounds, lock balance, absent extension/off switch, VBO
exclusion and sparse-range exclusion. It passes; repo invariants pass.
16-bit world-index and light-cache allocator changes have NOT been implemented.

Newest fat build source stamp:
91b6ab2e3e011ab3d6ae6d90e0ed35f9807c0c4ba4ce08da83ec866080eea701
Renderer MD5: 220706f3828b7ef8d5c22b64760b5b0c
Six slices built/fused successfully. Logs:
/private/tmp/q2-lock-arm64.log, /private/tmp/q2-lock-fat.log,
/private/tmp/q2-lock-tests.log.

Newest build deployed and renderer hash verified on mini-g4 only.
Quicksilver still has preceding sorting build 5119fb937c91.
G3 still has original candidate 447739046bce (verified).
Local /Applications/quake2 remains the earlier installed candidate, not
automatically updated by this follow-up.

## G3 recovered; no longer blocked

G3 stalled in state U after earlier screenshot/test activity. Stopped that
test sequence, attempted TERM/KILL (process survived), requested normal reboot.
SSH temporarily rejected authentication afterward, then recovered without
any key/config change. Tiger is running; the user was asked asynchronously
to check login, but this is now resolved. Use yosemite-tiger, not yosemite
(the latter's host-key mismatch was NOT bypassed).

Completed G3 isolation at 800x600, source447739046bce, bloom off:

| Setting | Runs | Warm FPS |
| --- | --- | ---: |
| All off | 39.3 / 39.3 / 39.3 | 39.30 |
| World only | 38.4 / 38.5 / 38.6 | 38.55 |
| Indexed only | 37.6 / 37.7 / 37.6 | 37.65 |
| Light cache only | 39.3 / 39.5 / 39.4 | 39.45 |

Evidence in g3/results.csv and g3/raw/. G3 profile has gl_dynamic 0;
don't call the tiny cache difference meaningful. Indexed rendering is the
largest isolated regression. Original gl_vertex_arrays default is 0,
so the default alias baseline is immediate mode: compiled-array locking
exists in other old paths but wasn't necessarily active in this baseline.

## RUNNING at handoff

Unified exec session 92563 is a mini-g4 lock-off/on test, holding that
machine's lock. Poll with write_stdin; do not start another mini-g4 task
until it finishes. It runs three timedemos per leg. Last observed output:
lock-off run1 40.2 FPS; run2 starting. Do not draw conclusions yet: earlier
combined run was 41.2; compare paired current legs, and verify effective
configuration if the discrepancy persists.

Outputs: /private/tmp/q2-lock-ab/results.csv and /private/tmp/q2-lock-ab/raw/.
Wrapper stages /private/tmp/q2-lock-off.cfg and q2-lock-on.cfg into
mini-g4:quake2-play/baseq2, then runs bench.sh with EXTRA='+exec q2-lock-off.cfg'
or on. Both configs set bloom0 world1 indexed0 cache1 sort0; only lock differs.
Raw log must confirm config execution; inspect actual cvars if results differ
from expectations. Six extra +set cvars exceed this engine's 50-argument cap,
so use config files through +exec, not a longer command line. The earlier
overlong launch produced no log/FPS and was stopped; no result was accepted.

G3 isolation session 24913 completed successfully; no G3 test is running.

## Next actions

1. Finish current mini-g4 lock A/B. Copy CSV/raw evidence into this directory.
2. Deploy newest fat to G3 under normal deploy lock and verify renderer MD5.
   Stage /private/tmp/q2-g3-lock-off.cfg and q2-g3-lock-on.cfg under a
   picker --run lock, then bench each via EXTRA='+exec <cfg>' at 800x600.
   These set world1 indexed1 cache0 sort1 bloom0; only locking differs.
   Use three runs, record warm average. If locking helps, test sorting
   separately (gl_worldsort 0) and the best combination against fresh all-off.
3. Validate frames for any retained setting. mini-g4 has tests/frames refs.
   G3 screenshot.sh hardcodes 1024x768 and its native-mode path stalled;
   override via EXTRA='+set gl_customwidth 800 +set gl_customheight 600
   +set vid_desktopfullscreen 0 +exec <test.cfg>' (keep under arg cap).
   Do not blindly rerun its default video setup. Use explicit same 800x600
   before/after frames to temporary SHOT_DIRs; no yosemite-tiger refs exist.
4. Keep or revert experimental behavior based on measurements; no global
   defaults based on GPU/CPU assumptions. gl_worldsort is default1 and
   gl_mesh_lockarrays default0, so unproven experiments remain opt-in.
5. Update report with actual evidence and hand off. Do not claim a large
   fleet win: confirmed G4 mini gain so far is only 40.85 -> 41.20 (+0.86%),
   world1 indexed0 cache1 sort0, with all ten frame comparisons passing.

Work is being saved in a local commit at the user's pause request. The
pre-existing SDL framework binary modification is excluded. Main changes for locking are r_geometry.c,
r_main.c, header/local.h and tests/renderer-refactor.c. README.md predates
the lock implementation and says G3 blocked; this handoff supersedes those
two stale portions. No need to redo finished sorting benches.
