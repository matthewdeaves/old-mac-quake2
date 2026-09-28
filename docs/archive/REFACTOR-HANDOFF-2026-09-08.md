# Renderer refactor handoff, 2026-09-08 (archived stale parts)

Moved out of `docs/REFACTOR-HANDOFF.md` on 2026-09-28. The switches, design notes and validation command stay in that file. The paused state and completed measurements are in `benchmarks/experiments/2026-09-08-refactor-isolation/NEXT-MODEL.md`, which supersedes everything below.

## Session framing

No experimental switch default was changed and no machine profile touched. No release candidate had been built or deployed in the implementation session; the user wanted that work after switching models.

## Bloom exclusion (stale)

Bloom was excluded because the user reported a black screen on Apple Silicon and possibly elsewhere. Every candidate and baseline run forced `gl_bloom 0`. Some machine profiles still enabled bloom, so profiles and historical bloom rows were not proof of current correctness. (The Apple Silicon readback fault was fixed 2026-09-12, BUGFIXES #33.)

## Implementation-session results

On the Apple Silicon implementation machine: the sanitizer harness passed at `-O2` and `-O3`; repository invariants and `git diff --check` passed; the changed renderer translation units passed ARM64 and x86_64 syntax checks with the local SDK. PPC compilation, full renderer linkage, real GL rendering, and FPS were unverified. Changes were left in the worktree for the release-candidate session, not committed or published.

## Next session plan: build, validate, bench

Follow `AGENTS.md`, `.claude/rules/commands.md`, `.claude/rules/facts.md`, and the current build-host workflow. Builds and CI are centralized on `old-mac-build-host`; use the shared host locks and release tooling, no local release build workflow. The implementation worktree also held a pre-existing modified `MacOSX/SDL.framework/Versions/A/SDL`; do not discard or silently attribute that binary change to this refactor.

1. Build the candidate through the established centralized workflow and verify every intended slice, dependencies, source stamp and deployed bytes. Include the new `r_geometry.o` from the Makefile. First verify the candidate with all three switches zero against the previous binary.
2. Validate images before accepting FPS. Cover static and animated textures, flowing surfaces, lightmap overbright, glass, water/caustics, fog, doors, monster/weapon interpolation, UV seams, translucent models, shell glows, blob and stencil shadows, moving/expired lights and lightstyle changes. Include map transitions and a real new game on base1. A timedemo alone is insufficient. Watch for seams or coplanar changes from opaque sorting and floating-point differences from texture-matrix scrolling.
3. For each target, compare `(staticworld,indexedmodels,lightmap_cache)`: `(0,0,0)`, `(1,0,0)`, `(2,0,0)`, `(0,1,0)`, `(0,0,1)`, then the best combination. Always pass `+set gl_bloom 0`. Use demo1, demo2 and effect-heavy scenes at real player resolutions, following the repository repetition and logging rules. Do not infer a VBO win from extension availability.
4. On the G3 and any G4 profile with dynamic lighting off, first measure the shipped-effects baseline. Then compare `gl_dynamic 1`, `gl_flashblend 0` with the lighting switch off/on at identical settings. Only after that assess whether real lighting is affordable versus the shipped appearance.
5. Bench G3, G4, G5, Intel and the Apple Silicon machine as requested. Resolve actual host aliases through shared tooling. Never schedule the two Yosemite OS aliases concurrently. Never switch the iMac G5 to a non-native fullscreen mode. Keep its existing guards and Jenkins workflow.
6. Record measured results and frame evidence, then choose per-machine defaults. Do not publish a final release solely because compilation or the CPU harness passed.

Example comparison overrides for the established bench workflow:

```
+set gl_bloom 0 +set gl_staticworld 0 +set gl_indexedmodels 0 +set gl_lightmap_cache 0
+set gl_bloom 0 +set gl_staticworld 1 +set gl_indexedmodels 1 +set gl_lightmap_cache 1
```
