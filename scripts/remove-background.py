#!/usr/bin/env python3
"""
Remove a near-uniform background from an RGB(A) PNG, preserving interior detail.

Used to prep icon source images from ChatGPT/DALL·E (which produce solid
white or solid black backgrounds) into transparent-bg PNGs suitable for
feeding into scripts/build-icon.py.

Algorithm (edge-flood-fill, the only safe way):

  1. Build a boolean "bg-candidate" mask: pixels matching the bg colour
     within a tolerance.
  2. Label connected components of that mask.
  3. Keep only components that touch the image edge — those are the actual
     background. Interior pixels matching the bg colour (e.g. specular
     highlights, the inside of an O-shaped letter, internal light areas)
     are preserved.
  4. For pixels in the kept components, set alpha to 0 (hard) or to a
     soft ramp based on how close to pure bg they are (anti-aliased edge).

Why not a simple `alpha = (pixel == bg) ? 0 : 255` threshold? That punches
holes in the interior wherever the icon legitimately has bg-coloured detail.
Step 3 above is the whole point of the script.

Usage:
  scripts/remove-background.py <input.png> <output.png> \
      [--bg white|black] [--hard N] [--soft N] [--magenta-preview path.png]

Defaults:
  --bg white        (assume solid white background)
  --hard 240        (pixels at this whiteness or above → fully transparent)
  --soft 200        (pixels at this whiteness or below → fully opaque;
                     in between, linear alpha ramp)

For black bg, --hard/--soft compare against darkness (max(RGB)) instead.
"""

import argparse
import sys
from PIL import Image
import numpy as np
from scipy import ndimage


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--bg", choices=["white", "black"], default="white",
                   help="background colour to strip (default: white)")
    p.add_argument("--hard", type=int, default=240,
                   help="hard threshold (default 240 — pixels this 'pure' or more → alpha=0)")
    p.add_argument("--soft", type=int, default=200,
                   help="soft threshold (default 200 — start of anti-alias ramp)")
    p.add_argument("--magenta-preview", default=None,
                   help="also save a magenta-composited debug view to this path")
    return p.parse_args()


def main():
    args = parse_args()
    img = Image.open(args.input).convert("RGBA")
    a = np.array(img)
    rgb = a[:, :, :3]

    # "Whiteness" for white-bg = min(R,G,B); for black-bg = 255 - max(R,G,B).
    # Both produce a 0..255 score where high = more like the bg colour.
    if args.bg == "white":
        score = rgb.min(axis=2)
    else:
        score = 255 - rgb.max(axis=2)

    # Step 1+2: hard mask = certain bg, soft mask = bg-or-edge-AA.
    # Flood-fill connectivity is done on the SOFT mask (so aliased edge
    # pixels with score in [soft, hard) are included), but only the hard
    # mask pixels get alpha=0 — soft mask pixels in the bg region get a
    # linear-ramp alpha based on their score.
    hard_mask = score >= args.hard
    soft_mask = score >= args.soft
    labeled, n_labels = ndimage.label(soft_mask)
    print(f"  hard-bg pixels: {hard_mask.sum():,} ({100*hard_mask.sum()/hard_mask.size:.1f}%)")
    print(f"  soft-bg pixels: {soft_mask.sum():,} ({100*soft_mask.sum()/soft_mask.size:.1f}%)")
    print(f"  connected components (soft mask): {n_labels}")

    # Step 3: keep only soft-mask components that contain at least one
    # hard-mask pixel that touches the image edge. This protects interior
    # near-bg-coloured regions even if they're connected through a soft
    # bridge to the outside — without this, a single aliased pixel between
    # an interior highlight and the bg could leak transparency inward.
    h, w = labeled.shape
    edge_labels = set()
    edge_labels.update(np.unique(labeled[0, :]))
    edge_labels.update(np.unique(labeled[-1, :]))
    edge_labels.update(np.unique(labeled[:, 0]))
    edge_labels.update(np.unique(labeled[:, -1]))
    edge_labels.discard(0)
    print(f"  edge-touching labels: {len(edge_labels)} "
          f"(pixel coverage: {100*np.isin(labeled, list(edge_labels)).sum()/labeled.size:.1f}%)")

    bg = np.isin(labeled, list(edge_labels))

    # Step 4: alpha ramp over [soft, hard].
    alpha = np.full_like(score, 255, dtype=np.uint8)
    in_bg = bg & soft_mask
    span = max(args.hard - args.soft, 1)
    ramp = 255 - np.clip(
        ((score[in_bg].astype(np.int32) - args.soft) * 255) // span,
        0, 255
    ).astype(np.uint8)
    alpha[in_bg] = ramp

    out = a.copy()
    out[:, :, 3] = alpha

    Image.fromarray(out, "RGBA").save(args.output, optimize=True)
    print(f"  wrote: {args.output}")
    print(f"    transparent pixels: {(alpha == 0).sum():,} ({100*(alpha == 0).sum()/alpha.size:.1f}%)")
    print(f"    opaque pixels:      {(alpha == 255).sum():,} ({100*(alpha == 255).sum()/alpha.size:.1f}%)")
    print(f"    feathered pixels:   {((alpha > 0) & (alpha < 255)).sum():,}")

    if args.magenta_preview:
        magenta = np.array([255, 0, 255], dtype=np.uint8)
        af = alpha.astype(np.float32) / 255.0
        composed = (out[:, :, :3].astype(np.float32) * af[..., None] +
                    magenta.astype(np.float32) * (1 - af[..., None])).astype(np.uint8)
        Image.fromarray(composed, "RGB").save(args.magenta_preview, optimize=True)
        print(f"  wrote: {args.magenta_preview} (magenta-composited preview)")


if __name__ == "__main__":
    main()
