#!/usr/bin/env python3
"""
make-icon.py — end-to-end Mac OS icon pipeline for the Q2 PPC port.

Takes a source PNG (any background — solid white, solid black, or already
transparent) and produces a Mac OS .icns file that renders correctly on
**every** target in our bench fleet:

  yosemite     10.3.9 Panther     PPC G3 (Rage 128)
  sawtooth     10.4.11 Tiger      PPC G4 (GeForce2 MX)
  quicksilver  10.4.11 Tiger      PPC G4 (Radeon 9000)
  mini-g4      10.4.11 Tiger      PPC G4 (Radeon 9200)
  mini-intel   10.7.5 Lion        x86_64 (GMA 950)
  imac-2019    15.7   Sequoia     x86_64 (Radeon Pro 580X)

Pipeline:

  1. Background removal (optional, default auto-detected from corner pixels).
     Edge-flood-fill so interior pixels matching the bg colour are not
     punched transparent. Soft alpha ramp at the edge for AA.

  2. ICNS assembly. **Legacy-only chunks** — ICN#, ics#, is32, s8mk, il32,
     l8mk, ih32, h8mk, it32, t8mk. No `TOC`, no modern PNG chunks
     (ic07/ic08/ic09/ic10/ic11/ic12/ic13/ic14). Why: Panther 10.3 Finder
     bails on the modern chunks even when they appear after the legacy
     ones, so a single .icns file that works on Panther + Tiger + Lion +
     Sequoia has to be legacy-only. Trade-off: Lion+ Retina renders by
     upscaling the 128×128 it32 chunk, instead of getting native 256-1024px
     PNG chunks. Worth it — the bench fleet's three Tigers and one Panther
     are the targets that historically broke; everything Lion+ has more
     icon-rendering flexibility.

     Why not `iconutil`? It unconditionally emits TOC + modern chunks, and
     doesn't produce 1-bit ICN#/ics# (Panther) chunks at all.

Usage:
  scripts/make-icon.py SOURCE [-o OUTPUT] [--bg COLOUR] [--preview PATH]
                              [--keep-bg] [--hard N] [--soft N]

Examples:
  # Default: auto-detect bg, write to MacOSX/Quake2.icns, drop preview alongside.
  scripts/make-icon.py docs/icon-source/quake2-source.png

  # Already-transparent PNG, just build the ICNS.
  scripts/make-icon.py docs/icon-source/quake2-transparent.png --keep-bg

  # Custom thresholds (white bg with weaker AA fringe).
  scripts/make-icon.py source.png --bg white --hard 245 --soft 220

Pre-reqs: Pillow, numpy, scipy. The project's ~/quake2/.venv has them.
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


# -----------------------------------------------------------------------------
# Stage 1 — background removal (edge-flood-fill + soft AA ramp)
# -----------------------------------------------------------------------------

def autodetect_bg(rgba: np.ndarray) -> str:
    """Look at the four corners. If they're all near-white return 'white',
    near-black 'black', otherwise raise — we can't guess."""
    h, w = rgba.shape[:2]
    corners = rgba[[0, 0, -1, -1], [0, -1, 0, -1], :3]
    brightness = corners.mean(axis=1)
    if (brightness >= 240).all():
        return "white"
    if (brightness <= 16).all():
        return "black"
    raise SystemExit(
        f"make-icon: cannot auto-detect background. Corner brightness = {brightness}. "
        "Pass --bg white|black|transparent explicitly."
    )


def remove_background(rgba: np.ndarray, bg: str, hard: int, soft: int,
                      scrub_interior: int = 0) -> np.ndarray:
    """Return a new RGBA array with bg pixels' alpha set to 0 (or feathered)
    and (mostly) interior pixels preserved.

    Algorithm:
      score = whiteness or darkness (0..255, high = more bg-like)
      hard_mask  = score >= hard
      soft_mask  = score >= soft  (includes AA edge band)
      labelled   = connected components of soft_mask
      bg_region  = labels that touch the image edge
      alpha      = 255 by default
                 = linear ramp in [soft, hard] for pixels in bg_region

    The "edge-touching only" filter usually protects legit interior near-bg
    pixels (specular highlights, internal logo whitespace). But sometimes
    the source artwork has *unwanted* interior bg-coloured pockets — e.g.
    bg showing through gaps in a logo glyph (between the strokes of an "I"
    in "II"), or through gaps between blood-splatter drops. Those pockets
    are isolated connected components of soft_mask that don't touch the
    canvas edge.

    The `scrub_interior` parameter: if > 0, any interior soft_mask
    component of size >= scrub_interior pixels is *also* treated as bg.
    Small components (single pixels, tiny specular flecks) stay opaque
    — only chunky interior bg-coloured pockets get scrubbed. A typical
    value for ChatGPT-generated icons is 30-100; default 0 keeps the
    conservative edge-only behaviour for general use."""
    rgb = rgba[:, :, :3]
    if bg == "white":
        score = rgb.min(axis=2)
    else:  # black
        score = 255 - rgb.max(axis=2)

    hard_mask = score >= hard
    soft_mask = score >= soft
    labelled, n_labels = ndimage.label(soft_mask)

    edge_labels = set()
    edge_labels.update(np.unique(labelled[0, :]))
    edge_labels.update(np.unique(labelled[-1, :]))
    edge_labels.update(np.unique(labelled[:, 0]))
    edge_labels.update(np.unique(labelled[:, -1]))
    edge_labels.discard(0)
    bg_region = np.isin(labelled, list(edge_labels))

    scrubbed_pockets = 0
    scrubbed_pixels = 0
    if scrub_interior > 0:
        # Find interior pure-bg pockets. Two-stage:
        #   1. Build a PURE-bg mask (score >= hard + 3), label its components.
        #      This excludes bright-but-not-pure pixels like metallic
        #      specular highlights (score 240-250) — they're not in the
        #      strict mask, so they aren't labeled as candidate pockets.
        #   2. Take strict-mask components that don't touch the canvas edge
        #      and exceed the size threshold.
        #   3. Expand each via binary_propagation through soft_mask, so the
        #      AA fringe around each pocket also goes transparent (no white
        #      halo left behind).
        purity_threshold = min(254, hard + 3)
        strict_mask = score >= purity_threshold
        strict_labelled, n_strict = ndimage.label(strict_mask)

        strict_edge = set()
        strict_edge.update(np.unique(strict_labelled[0, :]))
        strict_edge.update(np.unique(strict_labelled[-1, :]))
        strict_edge.update(np.unique(strict_labelled[:, 0]))
        strict_edge.update(np.unique(strict_labelled[:, -1]))
        strict_edge.discard(0)
        interior_strict = np.setdiff1d(np.arange(1, n_strict + 1),
                                       np.array(list(strict_edge)))
        if interior_strict.size > 0:
            sizes = ndimage.sum(strict_mask, strict_labelled, index=interior_strict)
            size_pass = interior_strict[sizes >= scrub_interior]
            # Per-pocket "what surrounds it?" filter. Bg-bleed-through pockets
            # are surrounded by DARK icon body (annulus mean score < 150).
            # Saturated specular highlights on metallic surfaces are
            # surrounded by a BRIGHT gradient (annulus mean score > 180).
            # The annulus is a 5px-wide ring just outside each pocket.
            real_bg = []
            for lbl in size_pass:
                pocket = (strict_labelled == lbl)
                annulus = ndimage.binary_dilation(pocket, iterations=5) & ~pocket
                if annulus.sum() == 0:
                    continue
                if score[annulus].mean() < 150:
                    real_bg.append(lbl)
            if real_bg:
                real_bg = np.array(real_bg)
                chunky_seed = np.isin(strict_labelled, real_bg)
                # Tight 2px dilation clipped to soft_mask to capture the
                # AA halo right around each scrubbed pocket (avoids leaving
                # a white fringe behind). Don't use binary_propagation —
                # it walks through every connected soft-mask pixel.
                chunky_dilated = ndimage.binary_dilation(chunky_seed, iterations=2)
                chunky_expanded = chunky_dilated & soft_mask
                bg_region = bg_region | chunky_expanded
                scrubbed_pockets = int(real_bg.size)
                scrubbed_pixels = int(chunky_expanded.sum())

    alpha = np.full_like(score, 255, dtype=np.uint8)
    in_bg = bg_region & soft_mask
    span = max(hard - soft, 1)
    ramp = 255 - np.clip(
        ((score[in_bg].astype(np.int32) - soft) * 255) // span,
        0, 255,
    ).astype(np.uint8)
    alpha[in_bg] = ramp

    out = rgba.copy()
    out[:, :, 3] = alpha

    stats = {
        "bg_pixels": int(bg_region.sum()),
        "transparent": int((alpha == 0).sum()),
        "feathered": int(((alpha > 0) & (alpha < 255)).sum()),
        "opaque": int((alpha == 255).sum()),
        "components": int(n_labels),
        "edge_labels": len(edge_labels),
        "scrubbed_pockets": scrubbed_pockets,
        "scrubbed_pixels": scrubbed_pixels,
    }
    return out, stats


def magenta_preview(rgba: np.ndarray) -> Image.Image:
    """Composite the transparent RGBA over a magenta background — makes
    alpha bleed and bg-removal mistakes obvious to the eye."""
    a = rgba[:, :, 3].astype(np.float32) / 255.0
    magenta = np.array([255, 0, 255], dtype=np.float32)
    composed = (
        rgba[:, :, :3].astype(np.float32) * a[..., None]
        + magenta * (1 - a[..., None])
    ).astype(np.uint8)
    return Image.fromarray(composed, "RGB")


# -----------------------------------------------------------------------------
# Stage 2 — ICNS assembly (legacy-only chunks)
# -----------------------------------------------------------------------------

def split_rgba(img: Image.Image) -> tuple[bytes, bytes, bytes, bytes]:
    """Return raw R, G, B, A channel bytes — faster + non-deprecated alternative
    to per-pixel iteration via getdata()."""
    r, g, b, a = img.split()
    return r.tobytes(), g.tobytes(), b.tobytes(), a.tobytes()


def rle_channel(data: bytes) -> bytes:
    """Apple ICNS legacy chunk RLE encoding.

      - Run of 3+ same bytes: 1 token byte (run_length + 125), 1 data byte. Run cap = 130.
      - Literal run:          1 token byte (length - 1),         N data bytes. Lit cap = 128.
    """
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        run = 1
        while i + run < n and data[i + run] == data[i] and run < 130:
            run += 1
        if run >= 3:
            out.append(run + 125)
            out.append(data[i])
            i += run
        else:
            ls = i
            while i < n:
                if i + 2 < n and data[i] == data[i + 1] == data[i + 2]:
                    break
                i += 1
                if i - ls >= 128:
                    break
            ll = i - ls
            out.append(ll - 1)
            out.extend(data[ls:ls + ll])
    return bytes(out)


def rgb_payload(img: Image.Image, size: int, with_it32_header: bool) -> bytes:
    """RGB chunk payload: three RLE'd channels concatenated.
    it32 (128x128) prefixes a 4-byte zero header; smaller sizes don't."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    r, g, b, _ = split_rgba(resized)
    payload = rle_channel(r) + rle_channel(g) + rle_channel(b)
    return (b"\x00\x00\x00\x00" + payload) if with_it32_header else payload


def mask_payload(img: Image.Image, size: int) -> bytes:
    """8-bit alpha mask payload: raw, uncompressed, 1 byte per pixel."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    _, _, _, a = split_rgba(resized)
    return a


def bw_pair(img: Image.Image, size: int) -> tuple[bytes, bytes]:
    """1-bit B&W bitmap + 1-bit mask (ICN# = 32×32, ics# = 16×16). The
    original Classic Mac OS icon format. Panther's Finder uses these as
    fallback when other chunks fail to parse.

    Bit packing: MSB-first, 8 pixels per byte. White = 0, black = 1.
    Mask bit = 1 where alpha > 16 (i.e. pixel is visible)."""
    resized = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    r, g, b, a = split_rgba(resized)
    bits = bytearray()
    mask = bytearray()
    bb = mb = nb = 0
    for i in range(len(a)):
        gray = (r[i] * 299 + g[i] * 587 + b[i] * 114) // 1000
        if a[i] > 16:
            bb = (bb << 1) | (1 if gray < 128 else 0)
            mb = (mb << 1) | 1
        else:
            bb = (bb << 1)
            mb = (mb << 1)
        nb += 1
        if nb == 8:
            bits.append(bb & 0xFF)
            mask.append(mb & 0xFF)
            bb = mb = nb = 0
    return bytes(bits), bytes(mask)


def chunk(fcc: bytes, payload: bytes) -> bytes:
    """One ICNS chunk = 4-byte FourCC + 4-byte big-endian total length + payload."""
    return fcc + struct.pack(">I", 8 + len(payload)) + payload


def build_icns(img: Image.Image) -> bytes:
    """Assemble the full legacy-only ICNS byte stream."""
    ib32, im32 = bw_pair(img, 32)
    ib16, im16 = bw_pair(img, 16)

    body = b""
    body += chunk(b"ICN#", ib32 + im32)
    body += chunk(b"ics#", ib16 + im16)
    body += chunk(b"is32", rgb_payload(img, 16, False))
    body += chunk(b"s8mk", mask_payload(img, 16))
    body += chunk(b"il32", rgb_payload(img, 32, False))
    body += chunk(b"l8mk", mask_payload(img, 32))
    body += chunk(b"ih32", rgb_payload(img, 48, False))
    body += chunk(b"h8mk", mask_payload(img, 48))
    body += chunk(b"it32", rgb_payload(img, 128, True))
    body += chunk(b"t8mk", mask_payload(img, 128))

    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def describe_icns(data: bytes) -> None:
    """Print chunk breakdown for verification."""
    total = struct.unpack(">I", data[4:8])[0]
    print(f"  ICNS total: {total:,} bytes")
    off = 8
    while off < total:
        fcc = data[off:off + 4].decode("ascii", errors="replace")
        sz = struct.unpack(">I", data[off + 4:off + 8])[0]
        print(f"    {fcc!r:<8s} {sz:>7,} bytes")
        off += sz


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__.strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("source", type=Path,
                   help="source PNG (any bg — white, black, or already-transparent)")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="output .icns path (default: MacOSX/Quake2.icns under repo root)")
    p.add_argument("--bg", choices=["auto", "white", "black", "transparent"], default="auto",
                   help="background colour to strip (default: auto-detect from corners). "
                        "'transparent' = source already has an alpha channel, skip removal.")
    p.add_argument("--keep-bg", action="store_true",
                   help="alias for --bg transparent")
    p.add_argument("--hard", type=int, default=250,
                   help="hard threshold — pixels this 'pure' or more → alpha=0 (default 250)")
    p.add_argument("--soft", type=int, default=200,
                   help="soft threshold — start of anti-alias ramp (default 200)")
    p.add_argument("--scrub-interior", type=int, default=0,
                   help="ALSO remove interior bg-coloured pockets ≥ N pixels in size "
                        "(default 0 = off, preserve all interior detail). "
                        "Useful for AI-generated icons with bg leaking through logo "
                        "glyph gaps. Try 50-200 for chunky pockets; lower for finer ones.")
    p.add_argument("--preview", type=Path, default=None,
                   help="also write a magenta-composited debug PNG to this path")
    p.add_argument("--intermediate", type=Path, default=None,
                   help="also save the post-bg-removal RGBA PNG here (for inspection)")
    return p.parse_args()


def repo_root_from(script_path: Path) -> Path:
    return script_path.resolve().parent.parent


def main() -> None:
    args = parse_args()
    repo = repo_root_from(Path(__file__))

    src = args.source
    if not src.is_file():
        sys.exit(f"make-icon: source not found: {src}")

    out = args.output or (repo / "MacOSX" / "Quake2.icns")
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"  source: {src}")
    img = Image.open(src).convert("RGBA")
    arr = np.array(img)
    print(f"    size: {img.size}  RGBA")

    if args.keep_bg:
        args.bg = "transparent"

    if args.bg == "transparent":
        print("  bg removal: skipped (source already transparent)")
    else:
        bg = autodetect_bg(arr) if args.bg == "auto" else args.bg
        print(f"  bg removal: {bg} bg, hard={args.hard} soft={args.soft}"
              + (f" scrub-interior={args.scrub_interior}" if args.scrub_interior else ""))
        arr, stats = remove_background(arr, bg, args.hard, args.soft, args.scrub_interior)
        img = Image.fromarray(arr, "RGBA")
        print(f"    components: {stats['components']:,}  edge-labels: {stats['edge_labels']}")
        if stats['scrubbed_pockets']:
            print(f"    scrubbed interior pockets: {stats['scrubbed_pockets']} "
                  f"({stats['scrubbed_pixels']:,} pixels)")
        print(f"    transparent: {stats['transparent']:,}  feathered: {stats['feathered']:,}  opaque: {stats['opaque']:,}")

    if args.intermediate:
        args.intermediate.parent.mkdir(parents=True, exist_ok=True)
        img.save(args.intermediate, optimize=True)
        print(f"  intermediate PNG: {args.intermediate}")

    if args.preview:
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        magenta_preview(arr).save(args.preview, optimize=True)
        print(f"  preview PNG: {args.preview}")

    print("  building ICNS (legacy-only chunks for Panther → Sequoia compat):")
    icns = build_icns(img)
    out.write_bytes(icns)
    describe_icns(icns)
    print(f"  output: {out}")


if __name__ == "__main__":
    main()
