#!/usr/bin/env bash
#
# rebuild-icon.sh — regenerate MacOSX/QuakeSpasm.icns from a source PNG.
#
# **Legacy-only ICNS pipeline.** The .icns produced here contains ONLY
# the classic legacy chunks (ICN# / ics# / is32 / s8mk / il32 / l8mk /
# ih32 / h8mk / it32 / t8mk). No `TOC`, no `ic07`-`ic14` modern PNG
# chunks. This is the format that works EVERYWHERE in the bench fleet:
#
#   yosemite (Panther 10.3) — Finder bails on the modern PNG chunks
#                              even when they appear after the legacy
#                              ones. ICN#-first legacy-only is the only
#                              format Panther reliably renders.
#   sawtooth, quicksilver, mini-g4 (Tiger 10.4) — same parser story.
#   mini-intel (Lion 10.7), imac-2019 (Sequoia 15.7) — Lion+ Finder
#                              upscales the 128×128 it32 chunk to bigger
#                              Retina sizes. Slight quality loss on the
#                              5K iMac vs a 1024×1024 PNG chunk would
#                              give, but the icon DOES render.
#
# Trade-off: shipping a single .icns that works on Panther + Tiger means
# accepting upscaled-128px on Retina. Worth it — bench fleet's two G4
# Tigers and the G3 Panther are the icon-display targets that historically
# broke; everything Lion+ has more icon-rendering flexibility.
#
# Why not iconutil? iconutil unconditionally emits TOC + the modern ic07-
# ic14 chunks, and Panther/Tiger Finder don't tolerate those (verified
# 2026-05-10 by progressively shrinking a known-good Apple Calculator.icns
# and the broken QS one until the last difference was the modern chunks).
# iconutil also doesn't produce ICN# / ics# (1-bit Panther chunks) at all.
#
# So the pipeline is pure Python: Pillow does Lanczos resizes for the
# 16/32/48/128 sizes, our hand-rolled RLE encoder produces the il32 / it32
# / etc. payloads, and we splice them together with size headers.
#
# Usage:
#   scripts/rebuild-icon.sh [source.png] [out.icns]
#     defaults: MacOSX/newiconfinal.png  →  MacOSX/QuakeSpasm.icns
#
# Pre-reqs: Pillow on Ubuntu (python3 -m pip install Pillow). No Lion
# round trip needed. Runs in ~1 second.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PNG="${1:-$REPO_ROOT/docs/icon-source/quake2-transparent.png}"
OUT_ICNS="${2:-$REPO_ROOT/MacOSX/Quake2.icns}"

if [ ! -f "$SRC_PNG" ]; then
  echo "[rebuild-icon] ERROR: source PNG not found: $SRC_PNG" >&2
  exit 2
fi

echo "[rebuild-icon] source: $SRC_PNG"
echo "[rebuild-icon] output: $OUT_ICNS"

# Step 1: Build legacy-only ICNS via Python.
echo "[rebuild-icon] step 1/2: build legacy ICNS chunks"
python3 <<EOF
import struct
from PIL import Image

def rle_channel(data):
    """Apple ICNS legacy chunk RLE encoding. Run >= 3 → byte+125 + data;
    literal → length-1 + data; both cap at 128/130 per token."""
    out = bytearray(); i = 0; n = len(data)
    while i < n:
        run = 1
        while i + run < n and data[i+run] == data[i] and run < 130:
            run += 1
        if run >= 3:
            out.append(run + 125); out.append(data[i]); i += run
        else:
            ls = i
            while i < n:
                if i+2 < n and data[i] == data[i+1] == data[i+2]:
                    break
                i += 1
                if i - ls >= 128: break
            ll = i - ls
            out.append(ll - 1); out.extend(data[ls:ls+ll])
    return bytes(out)

def rgb_payload(img, size, with_hdr):
    """24-bit RGB payload. it32 (128×128) prefixes a 4-byte zero header."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pix = list(img.getdata())
    p = (rle_channel(bytes(c[0] for c in pix)) +
         rle_channel(bytes(c[1] for c in pix)) +
         rle_channel(bytes(c[2] for c in pix)))
    return (b"\x00\x00\x00\x00" + p) if with_hdr else p

def mask_payload(img, size):
    """8-bit alpha-channel mask, raw."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    return bytes(p[3] for p in img.getdata())

def bw_pair(img, size):
    """Classic Mac OS 1-bit ICN# / ics# bitmap + mask, packed MSB-first."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pix = list(img.getdata())
    bits = bytearray(); mask = bytearray()
    bb = 0; mb = 0; nb = 0
    for r,g,b,a in pix:
        gray = (r*299 + g*587 + b*114) // 1000
        if a > 16:
            bb = (bb << 1) | (1 if gray < 128 else 0)
            mb = (mb << 1) | 1
        else:
            bb = (bb << 1); mb = (mb << 1)
        nb += 1
        if nb == 8:
            bits.append(bb); mask.append(mb)
            bb = mb = nb = 0
    return bytes(bits), bytes(mask)

def chunk(fcc, p):
    return fcc + struct.pack(">I", 8 + len(p)) + p

src = Image.open("$SRC_PNG").convert("RGBA")
print(f"  source: {src.size} {src.mode}")

ib32, im32 = bw_pair(src, 32)
ib16, im16 = bw_pair(src, 16)

body  = chunk(b"ICN#", ib32 + im32)
body += chunk(b"ics#", ib16 + im16)
body += chunk(b"is32", rgb_payload(src, 16,  False))
body += chunk(b"s8mk", mask_payload(src, 16))
body += chunk(b"il32", rgb_payload(src, 32,  False))
body += chunk(b"l8mk", mask_payload(src, 32))
body += chunk(b"ih32", rgb_payload(src, 48,  False))
body += chunk(b"h8mk", mask_payload(src, 48))
body += chunk(b"it32", rgb_payload(src, 128, True))
body += chunk(b"t8mk", mask_payload(src, 128))

total = 8 + len(body)
out = b"icns" + struct.pack(">I", total) + body
with open("$OUT_ICNS", "wb") as f:
    f.write(out)

print(f"  wrote {total} bytes:")
off = 8
while off < total:
    typ = out[off:off+4].decode("ascii", errors="replace")
    sz = struct.unpack(">I", out[off+4:off+8])[0]
    print(f"    {typ!r:<8s} {sz} bytes")
    off += sz
EOF

# Step 2: refresh docs/images PNG copies for README hero strip.
# Only runs if docs/images/ already exists — we don't need these until
# we have a README hero strip, and pre-creating the dir would be premature.
if [ -d "$REPO_ROOT/docs/images" ]; then
  echo "[rebuild-icon] step 2/2: refresh docs/images/quake2-icon*.png"
  python3 <<EOF
from PIL import Image
src = Image.open("$SRC_PNG").convert("RGBA")
src.resize((256, 256), Image.LANCZOS).save("$REPO_ROOT/docs/images/quake2-icon-256.png", optimize=True)
src.resize((1024, 1024), Image.LANCZOS).save("$REPO_ROOT/docs/images/quake2-icon.png", optimize=True)
EOF
else
  echo "[rebuild-icon] step 2/2: skipping docs/images/ refresh (dir does not exist yet)"
fi

echo "[rebuild-icon] done."
echo "[rebuild-icon] next: deploy with scripts/deploy.sh <machine> to ship the new icon"
