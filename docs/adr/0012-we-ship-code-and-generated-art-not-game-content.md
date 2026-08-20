# 12. We ship code and generated art, not game content

Date: 2026-08-20 (records practice from 2026-05-11 onward)
Status: accepted

## Decision

**No id Software content ever ships from this repo.** The user brings their own
`pak0.pak` / `pak1.pak` / `pak2.pak` and their retail `baseq2/players/` (without
which multiplayer models render invisible). Retail Quake II is on Steam and GOG;
the shareware `pak0.pak` also works. Same rule for the Linux server tarball
(ADR 0011).

Everything the `.app` does ship is either our own code or **procedurally
generated at build time**, which is what keeps it GPL-clean:

- **Decal and shadow textures**, authored by `scripts/gen-decals.py` (PIL): the
  four originals `bullet` / `blood` / `greenblood` / `scorch` at 64x64 RGBA, plus
  `burn` (128x128, rocket), `plasma` (64x64), `bfg` (128x128), `rail` (64x64) and
  `shadow.tga` (64x64, opaque-black centre with radial alpha falloff). All RGBA
  TGA, so the existing `R_FindImage` loader picks them up. They are reported at
  load, `Decals: burn=OK plasma=OK bfg=OK rail=OK`.
- **Caustic and shell textures**, generated in `R_InitCausticTexture` and
  `R_InitParticleTexture` (`r_misc.c`). There is no asset to edit; tuning is in
  `docs/CONFIG.md`.
- **The app icon**, from `scripts/make-icon.py`.

## Retexturing is plumbed, but no pack ships

`WITH_RETEXTURING=yes` is compiled into every slice since commit `3b594e1`,
which switched `jpeg.c` from libjpeg to a vendored `stb_image.h` and dropped the
external dependency that had forced `WITH_RETEXTURING=no`.

Two install paths, both operator-supplied:

1. **`baseq2/textures/…` next to the paks.** Per-user, mix-and-match.
2. **`Quake2.app/Contents/Resources/hd-pak/…`**, making the `.app`
   self-contained. `Q2_GetBundleHDPakPath` (`yquake2/src/common/misc.c`)
   resolves it via `CFBundleCopyResourceURL` and
   `FS_InitFilesystem` (`filesystem.c`) adds it to the search chain. The
   directory is added **directly**, with no `/baseq2` suffix, so files live at
   `hd-pak/<gamerel>` matching `R_FindImage("textures/e1u1/wall1_1.tga")`.
   `fs_gamedir` is explicitly preserved as `baseq2` afterwards, so `config.cfg`
   and savegames still write to the user-visible directory rather than the
   read-only bundle.

Bundling a pack costs 200–500 MB of `.app` size and a slower deploy rsync, which
is why nothing is bundled by default.

## The app icon is a legacy ICNS, and stops at "good enough"

`scripts/make-icon.py` emits a **legacy-only ICNS** that renders in Panther
10.3, Tiger 10.4, Lion 10.7 and Sequoia 15.7 Finder. Two constraints drive that:

- **No `iconutil`** — it drops the 1-bit chunks Panther needs.
- **No modern PNG chunks** — they break Panther's Finder.

Background removal is deliberately conservative: edge flood fill that preserves
all interior detail, with no auto-scrubbing of interior background-coloured
pockets. The `--scrub-interior` knob exists, but its heuristics (size,
score-purity, annulus darkness) cannot reliably tell background bleed from
saturated specular highlights on metal.

**Use a Photoshop touch-up rather than chasing algorithmic perfection.** The
proven workflow: run with defaults to get a conservative transparent master plus
a magenta-composited preview; paint the visible pockets to alpha 0 by hand using
the preview as a guide; hand the RGBA PNG back with `--keep-bg` to regenerate
the ICNS without re-running background removal.

## Consequences

- The DMG is small and legally clean.
- Adding a visual feature that needs art means adding a generator, not an asset.
- **Any texture created once at init and held in a global must be added to the
  `R_FreeUnusedImages` protect block**, the same way `r_notexture` and
  `r_particletexture` are, or it is freed at the next map load and the feature
  path then binds a deleted texnum (see `MISTAKES.md`, 2026-05-29).
