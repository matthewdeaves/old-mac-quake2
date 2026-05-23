# HD texture pack — install + bundle guide

`WITH_RETEXTURING=yes` is now compiled into every slice (g3, g4, lion)
as of commit `3b594e1` — `jpeg.c` switched from libjpeg to a vendored
stb_image header, dropping the external dep that previously forced
`WITH_RETEXTURING=no` in `scripts/build.sh`.

With retexturing on, the engine looks for TGA / JPG replacements for
every `.pcx` / `.wal` texture it loads from `baseq2/pak0.pak`. The
search order is dictated by the order in which game directories were
added to the filesystem search chain (`FS_AddGameDirectory` —
newest-first). A successful lookup uses the hi-res replacement; a miss
falls back transparently to the original 256×256 source asset.

## Two install paths

### 1. Drop pack into the user's `baseq2/` (simple, per-user)

End-user puts the HD textures next to their pak files:

```
~/Desktop/quake2/
  Quake2.app/
  baseq2/
    pak0.pak     ← retail data
    pak1.pak
    pak2.pak
    textures/    ← HD replacements at game-relative paths
      e1u1/wall1_1.tga
      e1u1/floor1_1.tga
      ...
    players/
      male/grunt.tga
      ...
```

Pros: any user can mix in their own pack. Cons: ships separately from
the `.app`; user has to source it.

### 2. Bundle pack inside `Quake2.app/Contents/Resources/hd-pak/`
(self-contained `.app`, distributable)

The engine now checks for an `hd-pak` subdirectory inside the running
bundle's Resources at `FS_InitFilesystem` time (Mac builds only). If
found, it's added to the filesystem search chain so the contents are
visible at every gl_retexturing lookup. Layout:

```
Quake2.app/Contents/Resources/
  hd-pak/
    textures/
      e1u1/wall1_1.tga
      ...
    players/
      male/grunt.tga
      ...
    decals/
      bullet.tga    ← shipped procedurally
      blood.tga
      greenblood.tga
      scorch.tga
```

The `hd-pak/` directory is added to the searchpath chain directly
(no `/baseq2` suffix appended). Files live under `hd-pak/<gamerel>`,
matching the path used in `R_FindImage("textures/e1u1/wall1_1.tga")`
or `R_FindImage("decals/bullet.tga")`.

To stage textures this way:
1. Drop the pack source into `scripts/bundle/hd-pak/baseq2/...`
   (a directory you create; not currently checked in).
2. Modify `scripts/deploy.sh` to `cp -r scripts/bundle/hd-pak`
   into `$APP/Contents/Resources/` next to the cfg copies.
3. Rebuild fat + redeploy. The pack ships with the binary.

Pros: one self-contained drop, runs on every machine without per-host
texture install. Cons: balloons `.app` size by ~200-500 MB; deploy
rsync gets slower (rsync --partial / checksum-mode mitigates).

The bundle-search hook is in
`yquake2/src/common/misc.c:Q2_GetBundleHDPakPath` (resolves via
`CFBundleCopyResourceURL`) and wired into
`yquake2/src/common/filesystem.c:FS_InitFilesystem`. fs_gamedir is
explicitly preserved as `baseq2` after the bundle path is added so
config.cfg / savegames still write to the user-visible dir, not the
read-only bundle.

## Recommended packs

The author has not committed to one specific pack — these are
candidates worth evaluating. None of them are bundled in this repo;
sourcing is left to the operator.

| Pack | Source | License | Notes |
|---|---|---|---|
| **NeuralUpscale 2x** | community AI upscale of id1 baseq2 textures | derivative — id1 EULA | Most accessible. ~400MB. Available on the Quake2 modding circuit. Looks natural; no artistic reinterpretation. |
| **Berserker @ Quake2 HD** | Berserker mod team | freeware | ~200MB. Heavily reworked textures with painted detail. Visually impressive but more "modernized" than faithful. |
| **id1 retextured (Quaddicted)** | various | per-asset, often CC | Several smaller packs for specific areas; mix and match. |
| **Quake2-RTX assets** | NVIDIA Quake 2 RTX | restricted (NVIDIA EULA) | High quality but EULA limits redistribution; only usable with NVIDIA's own engine fork in practice. |

Practical recommendation: start with NeuralUpscale 2x for quicksilver
/ mini-g4 / mini-intel (32-64 MB VRAM) and the imac-2019 (8 GB
laughs). Skip the HD path entirely on yosemite (16 MB VRAM Rage 128 —
`gl_retexturing 0` in autoexec-yosemite.cfg already opts out).

## Per-machine HD on/off matrix

| Machine | gl_retexturing | VRAM budget | Notes |
|---|---|---|---|
| yosemite (R128 16MB)     | 0 | tight | Cannot afford full-res replacements; stay on the 256×256 baseline. |
| sawtooth (GF2 MX 32MB)   | 0 | tight | Could fit a subset but CPU TGA decode on the 500 MHz G4 dominates map-load. Skip. |
| quicksilver (R9000 64MB) | 1 | comfortable | Targeted candidate for the first HD experiment. |
| mini-g4 (R9200 32MB)     | 1 | viable | Tight but works for moderate packs. |
| mini-intel (GMA 950 64MB)| 1 | comfortable | Intel GMA driver handles TGA/JPG fine. |
| imac-2019 (Polaris 8GB)  | 1 | unbounded | Send it. Even 4K-upscaled packs fit. |

## How to verify a pack is loading

After dropping textures into either install path, launch and check
`qconsole.log`:

```
$ grep -E "Loading retex|texture .* failed" ~/.yq2/baseq2/qconsole.log
```

A clean retex load doesn't print anything by default — it's silent
success. To see which textures the engine looked up, enable
`developer 1` and watch for `LoadJPG: ...` / `LoadTGA: ...` lines.

To bench A/B impact, run the same demo with retexturing on vs off:

```
EXTRA='+cmd "set gl_retexturing 0"' scripts/bench.sh <machine> demo1 1024x768 3
EXTRA='+cmd "set gl_retexturing 1"' scripts/bench.sh <machine> demo1 1024x768 3
```

Typical impact: <5% fps cost when the pack is loaded (TGA / JPG decode
is a one-time per-texture cost paid at map load, not per-frame).

## Future engine work

- A small `gl_max_retex_size` cvar to clamp uploaded texture dim
  per-machine (skip 1024×1024 replacements on the 16 MB R128 even if
  the pack ships them).
- `gl_retex_mipmap_quality` to choose between mip-generation cost
  vs runtime sample quality.
- `r_image_palettized` retexture mode for paletted-only chips
  (Rage 128) — pre-quantize the HD pack to 8-bit at map load.

None of these block shipping an HD pack today. The plumbing now in
place is enough.
