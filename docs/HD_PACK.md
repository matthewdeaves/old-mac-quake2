# HD texture pack — install guide

Why no pack ships, and how the bundle search path is wired: **ADR 0012**.

With `WITH_RETEXTURING=yes` (compiled into every slice since `3b594e1`) the
engine looks for TGA/JPG replacements for every `.pcx` / `.wal` it loads from
`baseq2/pak0.pak`. Search order follows the order game directories were added to
the filesystem chain (`FS_AddGameDirectory`, newest first). A miss falls back
transparently to the original 256x256 asset.

## Two install paths

**1. Next to the paks** (per-user, mix and match):

```
~/Desktop/quake2/
  Quake2.app/
  baseq2/
    pak0.pak  pak1.pak  pak2.pak
    textures/e1u1/wall1_1.tga …
    players/male/grunt.tga …
```

**2. Inside the bundle** (self-contained `.app`):

```
Quake2.app/Contents/Resources/hd-pak/
  textures/e1u1/wall1_1.tga …
  players/male/grunt.tga …
  decals/bullet.tga  blood.tga  greenblood.tga  scorch.tga …
```

The `hd-pak/` directory is added to the search chain **directly**, with no
`/baseq2` suffix, so files sit at `hd-pak/<gamerel>`, matching
`R_FindImage("textures/e1u1/wall1_1.tga")` and
`R_FindImage("decals/bullet.tga")`.

To stage a pack this way: drop the source into `scripts/bundle/hd-pak/` (a
directory you create; not checked in), have `scripts/deploy.sh` `cp -r` it into
`$APP/Contents/Resources/` next to the cfg copies, then rebuild fat and
redeploy. Cost: 200-500 MB of `.app` size and a slower deploy rsync.

## Per-machine on/off

| Machine | `gl_retexturing` | VRAM | Note |
|---|---|---|---|
| yosemite (R128 16 MB) | 0 | tight | cannot afford full-res replacements |
| sawtooth (GF2 MX 32 MB) | 0 | tight | would fit a subset, but CPU TGA decode on a 500 MHz G4 dominates map load |
| quicksilver (R9000 64 MB) | 1 | comfortable | first HD experiment candidate |
| mini-g4 (R9200 32 MB) | 1 | viable | tight, works for moderate packs |
| mini-intel (GMA 950 64 MB) | 1 | comfortable | Intel driver handles TGA/JPG fine |
| imac-2019 (Polaris 8 GB) | 1 | unbounded | even 4K upscales fit |

## Candidate packs

None are bundled; sourcing is the operator's.

| Pack | Licence | Notes |
|---|---|---|
| NeuralUpscale 2x | derivative, id1 EULA | ~400 MB, community AI upscale. Most accessible; natural, no reinterpretation |
| Berserker @ Quake2 HD | freeware | ~200 MB, heavily reworked with painted detail; more modernised than faithful |
| id1 retextured (Quaddicted) | per-asset, often CC | several smaller area-specific packs |
| Quake2-RTX assets | NVIDIA EULA, restricted | high quality but redistribution-limited; in practice only usable with NVIDIA's fork |

## Verifying and measuring

A clean retex load prints nothing — it is silent success. Set `developer 1` to
see `LoadJPG:` / `LoadTGA:` lines, or:

    grep -E "Loading retex|texture .* failed" ~/.yq2/baseq2/qconsole.log

A/B the cost:

    EXTRA='+cmd "set gl_retexturing 0"' scripts/bench.sh <machine> demo1 1024x768 3
    EXTRA='+cmd "set gl_retexturing 1"' scripts/bench.sh <machine> demo1 1024x768 3

Typical impact is **under 5% fps**: decode is a one-time per-texture cost paid
at map load, not per frame.

## Not implemented

Three engine knobs would help the tightest machines and none of them blocks
shipping a pack today: `gl_max_retex_size` to clamp uploaded texture dimensions
per machine; `gl_retex_mipmap_quality` to trade mip generation cost against
sample quality; and a palettised retexture mode that pre-quantises to 8-bit at
map load for the Rage 128.
