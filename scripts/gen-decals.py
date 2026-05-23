#!/usr/bin/env python3
"""
Generate procedural decal textures for the Q2 PPC port.

Output: yquake2/baseq2-extra/decals/*.tga (TGA so the engine's existing
TGA loader picks them up via WITH_RETEXTURING).

Three decals:
  bullet.tga   — concentric soft circle, dark center, alpha-fading edge
  blood.tga    — irregular red splatter with soft alpha edge
  scorch.tga   — radial black scorch with feathered edge

All at 64×64 — small enough that even a few dozen in flight is < 1 MB
of VRAM. Yosemite's R128 (16 MB VRAM) tolerates ~30 simultaneous decals.

Style: deliberately simple/iconic so they read at retro resolutions.
The user can replace with prettier artwork later by dropping into
baseq2/decals/ — engine pathing prefers user paks over built-in.
"""

import os
import math
import random
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "yquake2", "baseq2-extra", "decals")
os.makedirs(OUT, exist_ok=True)

SIZE = 64
HALF = SIZE // 2


def bullet_hole():
    """Dark circle with soft alpha fade. Two concentric rings give a
    hint of impact depth."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            # alpha falls off from 1.0 at r=0 to 0.0 at r=28
            if r < 8:
                a = 220       # dark core
                lum = 30
            elif r < 16:
                a = int(220 * (1.0 - (r - 8) / 8.0)) + 40  # ring
                lum = 30 + int(30 * (r - 8) / 8.0)
            elif r < 26:
                a = max(0, int(120 * (1.0 - (r - 16) / 10.0)))
                lum = 60
            else:
                a = 0
                lum = 0
            px[x, y] = (lum, lum, lum, a)
    return img.filter(ImageFilter.GaussianBlur(radius=0.7))


def blood_splat():
    """Irregular red splat — main blob plus 4-6 droplets at random
    distances/angles. Deterministic seed so the texture is the same
    across builds."""
    random.seed(0xb100d)
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # main central blob
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            if r < 20:
                a = int(230 * (1.0 - r / 22.0))
                px[x, y] = (140, 5, 5, max(0, a))
            else:
                px[x, y] = (0, 0, 0, 0)

    # outer droplets
    for _ in range(8):
        ang = random.uniform(0, 2 * math.pi)
        dist = random.uniform(18, 28)
        cx = int(HALF + math.cos(ang) * dist)
        cy = int(HALF + math.sin(ang) * dist)
        rad = random.randint(2, 5)
        for y in range(max(0, cy - rad - 1), min(SIZE, cy + rad + 1)):
            for x in range(max(0, cx - rad - 1), min(SIZE, cx + rad + 1)):
                dx = x - cx
                dy = y - cy
                r = math.sqrt(dx * dx + dy * dy)
                if r < rad:
                    a = int(200 * (1.0 - r / float(rad)))
                    # combine with existing
                    old = img.getpixel((x, y))
                    new_a = min(255, old[3] + a)
                    img.putpixel((x, y), (140, 5, 5, new_a))

    return img.filter(ImageFilter.GaussianBlur(radius=0.5))


def scorch_mark():
    """Radial black scorch — strong center, feathered edge with
    some randomness."""
    random.seed(0x5c0c)
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    # base radial
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            # per-angle randomness for irregular edge
            ang = math.atan2(dy, dx)
            wobble = 1.0 + 0.15 * math.sin(ang * 7) + 0.10 * math.sin(ang * 11 + 1.3)
            r_eff = r / wobble
            if r_eff < 10:
                a = 240
            elif r_eff < 28:
                a = int(240 * (1.0 - (r_eff - 10) / 18.0))
            else:
                a = 0
            px[x, y] = (10, 8, 6, max(0, a))
    return img.filter(ImageFilter.GaussianBlur(radius=1.0))


def save_tga(img, name):
    """Save as TGA — yquake2 loads TGA via files/tga.c. Use uncompressed
    32-bit RGBA, top-down (bit 5 of image descriptor set), which is the
    most compatible variant."""
    path = os.path.join(OUT, name + ".tga")
    img.save(path, format="TGA")
    print(f"  {path}  ({os.path.getsize(path)} bytes)")


print(f"Generating decals in {OUT}/")
save_tga(bullet_hole(), "bullet")
save_tga(blood_splat(), "blood")
save_tga(scorch_mark(), "scorch")
print("done.")
