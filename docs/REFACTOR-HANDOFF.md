# Renderer refactor candidate, 2026-09-08

Historical implementation notes below. Current paused state, completed fleet
measurements and next steps are in
`benchmarks/experiments/2026-09-08-refactor-isolation/NEXT-MODEL.md`.
That handoff supersedes this document's older build/deploy status.

Implementation for the requested world geometry, indexed MD2, and dynamic
lighting refactors. Experimental switches default to zero. No machine profile
has been changed. No release candidate has been built or deployed in this
implementation session; the user wants that work after switching models.

## Switches

| Cvar | Baseline | Candidate |
| --- | --- | --- |
| `gl_staticworld` | `0`: existing world drawing | `1`: retained client arrays; `2`: attempt ARB VBO, fall back to retained client arrays |
| `gl_indexedmodels` | `0`: existing MD2 command stream | `1`: indexed model and projected-shadow drawing |
| `gl_lightmap_cache` | `0`: existing lighting | `1`: bounded static-light cache, bounded light columns, grouped world dynamic uploads |

The switches can be changed without a video restart. Geometry is built at map
load when enabled, or on first use after enabling. Failed/unsupported geometry
caches fall back until the next map/model load. Each comparison should start a
fresh process with explicit values for all switches. Keep `gl_groupdraw` and
all visual settings identical between comparison legs.

Bloom is excluded. The user reports a black screen on Apple Silicon and
possibly elsewhere. Force `gl_bloom 0` in every candidate and baseline run.
Some existing machine profiles still enable bloom, so do not rely on the
profile or historical bloom benchmark rows as proof of current correctness.

## What changed

- `r_geometry.c`: immutable world vertices and triangulated indices, with
  per-frame visible index batches. Client arrays work without VBO support;
  mode 2 resolves ARB buffer functions at runtime. World geometry storage is
  capped at 8 MiB plus surface ranges. Transparency and warped water keep
  their existing paths. The world queue sorts opaque surfaces in 256-unit
  depth bands, then by material/lightmap. Inline brush models keep their
  existing submission path.
- MD2 command streams are decoded into indexed triangles, deduplicated by
  source vertex and exact UV bits. Strip winding and fan order are preserved.
  Each source vertex is interpolated by the existing scalar/AltiVec code and
  lit once; seam vertices gather the resulting data. Shadows reuse topology
  and project source vertices once. Blob shadows remain the existing quad.
  No new architecture-specific SIMD kernel or shader backend was added.
- `r_light.c`: pre-dynamic floating-point light is cached with RGB style and
  modulation keys. The cache has 128 entries and a 256 KiB luxel-data budget.
  Minlight and final saturation still run after dynamic lighting. Conservative
  column bounds complement the existing row cull, retaining the old luxel
  distance/rounding predicate. The scratch-size guard now uses the actual
  three-float luxel capacity rather than dividing its byte size by sixteen.
- `r_surf.c`: visible dynamic world surfaces can use four temporary mirror
  atlases, retaining the source atlases' non-overlapping slots and UVs. Each
  used page is uploaded before its draws. Excess pages and upload errors
  use the old per-surface path. CPU page storage is about 256 KiB; GPU pages
  are allocated lazily. Single-TMU and inline-brush lighting retain their
  upload paths but use the CPU cache/column optimization when enabled.

The atlas preparation currently covers dlight-touched surfaces. Animated
lightstyles without a dlight retain their existing upload path. Sorting and
cache bookkeeping can cost more than they save on some drivers/scenes;
none of these defaults should be enabled from source inspection alone.

## Local validation

Run `bash tests/test-renderer-refactor.sh`. It compiles the production geometry,
light, and surface code into a recording-GL harness with AddressSanitizer and
UndefinedBehaviorSanitizer. It checks strip/fan winding, UV seams, alpha,
shadow projection, batching, client/VBO vertex parity, array/buffer cleanup,
malformed MD2 streams, byte-identical lightmaps against the disabled path,
cache invalidation/eviction, dynamic atlas slots, and overflow/error fallback.

Also run `bash tests/test-repo.sh` and `git diff --check`. Syntax checks with
the local macOS SDK are useful but are not PPC compiler or driver validation.
The harness does not rasterize pixels or measure FPS.

Implementation-session results on this Apple Silicon machine: the sanitizer
harness passed at `-O2` and `-O3`; repository invariants and `git diff --check`
passed; the changed renderer translation units passed ARM64 and x86_64 syntax
checks with the local SDK. PPC compilation, full renderer linkage, real GL
rendering, and FPS remain unverified. Changes are left in the worktree for the
release-candidate session, not committed or published.

## Next session: build, validate, bench

Follow `AGENTS.md`, `.claude/rules/commands.md`, `.claude/rules/facts.md`, and
the current build-host workflow. Builds/CI are centralized on
`old-mac-build-host`. Use the shared host locks and release tooling. Do not
introduce a local release build workflow. The implementation worktree also
contains a pre-existing modified `MacOSX/SDL.framework/Versions/A/SDL`; do not
discard or silently attribute that binary change to this refactor.

1. Build the candidate through the established centralized workflow and
   verify every intended slice, dependencies, source stamp and deployed bytes.
   Include the new `r_geometry.o` from the Makefile. First verify the candidate
   with all three switches zero against the previous binary.
2. Validate images before accepting FPS. Cover static and animated textures,
   flowing surfaces, lightmap overbright, glass, water/caustics, fog, doors,
   monster/weapon interpolation, UV seams, translucent models, shell glows,
   blob and stencil shadows, moving/expired lights and lightstyle changes.
   Include map transitions and a real new game on base1. A timedemo alone is
   insufficient. Watch for seams or coplanar changes from opaque sorting and
   floating-point differences from texture-matrix scrolling.
3. For each target, compare `(staticworld,indexedmodels,lightmap_cache)`:
   `(0,0,0)`, `(1,0,0)`, `(2,0,0)`, `(0,1,0)`, `(0,0,1)`, then the best
   combination. Always pass `+set gl_bloom 0`. Use demo1, demo2 and effect-heavy
   scenes at real player resolutions, following the repository repetition and
   logging rules. Do not infer a VBO win from extension availability.
4. On the G3 and any G4 profile with dynamic lighting off, first measure the
   shipped-effects baseline. Then compare `gl_dynamic 1`, `gl_flashblend 0`
   with the lighting switch off/on at identical settings. Only after that
   assess whether real lighting is affordable versus the shipped appearance.
5. Bench G3, G4, G5, Intel and this Apple Silicon machine as requested. Resolve
   actual host aliases/availability through shared tooling. Never schedule the
   two Yosemite OS aliases concurrently. Never switch the iMac G5 to a
   non-native fullscreen mode. Keep its existing guards and Jenkins workflow.
6. Record measured results and frame evidence, then choose per-machine
   defaults. Do not publish a final release solely because compilation or
   the CPU harness passed.

Example comparison overrides for the established bench workflow:

```
+set gl_bloom 0 +set gl_staticworld 0 +set gl_indexedmodels 0 +set gl_lightmap_cache 0
+set gl_bloom 0 +set gl_staticworld 1 +set gl_indexedmodels 1 +set gl_lightmap_cache 1
```
