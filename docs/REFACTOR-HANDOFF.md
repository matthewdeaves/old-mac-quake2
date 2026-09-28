# Renderer refactor candidate

Design notes for three experimental renderer switches (world geometry, indexed MD2, dynamic-light cache), all defaulting to zero, with no machine profile changed. Paused state, completed fleet measurements and next steps are in `benchmarks/experiments/2026-09-08-refactor-isolation/NEXT-MODEL.md`, which supersedes any build/deploy status. The stale session narrative and next-session plan are in `docs/archive/REFACTOR-HANDOFF-2026-09-08.md`.
Sections: Switches, What changed, Local validation.

## Switches

| Cvar | Baseline | Candidate |
| --- | --- | --- |
| `gl_staticworld` | `0`: existing world drawing | `1`: retained client arrays; `2`: attempt ARB VBO, fall back to retained client arrays |
| `gl_indexedmodels` | `0`: existing MD2 command stream | `1`: indexed model and projected-shadow drawing |
| `gl_lightmap_cache` | `0`: existing lighting | `1`: bounded static-light cache, bounded light columns, grouped world dynamic uploads |

The switches can be changed without a video restart. Geometry is built at map load when enabled, or on first use after enabling. Failed/unsupported geometry caches fall back until the next map/model load. Start each comparison in a fresh process with explicit values for all switches. Keep `gl_groupdraw` and all visual settings identical between legs. Force `gl_bloom 0` in every run.

## What changed

- `r_geometry.c`: immutable world vertices and triangulated indices, with per-frame visible index batches. Client arrays work without VBO support; mode 2 resolves ARB buffer functions at runtime. World geometry storage is capped at 8 MiB plus surface ranges. Transparency and warped water keep their existing paths. The world queue sorts opaque surfaces in 256-unit depth bands, then by material/lightmap. Inline brush models keep their existing submission path.
- MD2 command streams are decoded into indexed triangles, deduplicated by source vertex and exact UV bits. Strip winding and fan order are preserved. Each source vertex is interpolated by the existing scalar/AltiVec code and lit once; seam vertices gather the resulting data. Shadows reuse topology and project source vertices once. Blob shadows remain the existing quad. No new architecture-specific SIMD kernel or shader backend was added.
- `r_light.c`: pre-dynamic floating-point light is cached with RGB style and modulation keys. The cache has 128 entries and a 256 KiB luxel-data budget. Minlight and final saturation still run after dynamic lighting. Conservative column bounds complement the existing row cull, retaining the old luxel distance/rounding predicate. The scratch-size guard now uses the actual three-float luxel capacity rather than dividing its byte size by sixteen.
- `r_surf.c`: visible dynamic world surfaces can use four temporary mirror atlases, retaining the source atlases' non-overlapping slots and UVs. Each used page is uploaded before its draws. Excess pages and upload errors use the old per-surface path. CPU page storage is about 256 KiB; GPU pages are allocated lazily. Single-TMU and inline-brush lighting retain their upload paths but use the CPU cache/column optimization when enabled.

Atlas preparation covers dlight-touched surfaces only; animated lightstyles without a dlight keep their existing upload path. Sorting and cache bookkeeping can cost more than they save on some drivers/scenes: enable none of these defaults from source inspection alone.

## Local validation

Run `bash tests/test-renderer-refactor.sh`. It compiles the production geometry, light, and surface code into a recording-GL harness with AddressSanitizer and UndefinedBehaviorSanitizer, and checks strip/fan winding, UV seams, alpha, shadow projection, batching, client/VBO vertex parity, array/buffer cleanup, malformed MD2 streams, byte-identical lightmaps against the disabled path, cache invalidation/eviction, dynamic atlas slots, and overflow/error fallback.

Also run `bash tests/test-repo.sh` and `git diff --check`. Syntax checks with the local macOS SDK are not PPC compiler or driver validation. The harness does not rasterize pixels or measure FPS.
