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


def green_blood_splat():
    """Identical structure to blood_splat but in green-yellow — Strogg
    blood per Q2 lore. RGB (120, 180, 30) saturates well against beige
    base textures."""
    random.seed(0x9e10)  # different seed → different droplet pattern
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()

    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            if r < 20:
                a = int(230 * (1.0 - r / 22.0))
                px[x, y] = (120, 180, 30, max(0, a))
            else:
                px[x, y] = (0, 0, 0, 0)

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
                    old = img.getpixel((x, y))
                    new_a = min(255, old[3] + a)
                    img.putpixel((x, y), (120, 180, 30, new_a))

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


def burn_mark():
    """Big rocket burn — 128px. Dark charred core, irregular sooty edge,
    faint radial blast streaks radiating out. The 'big old explosion
    mark' — deliberately the biggest/darkest of the set."""
    random.seed(0xb09b)
    S = 128
    H = S // 2
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    px = img.load()
    streaks = [random.uniform(0, 2 * math.pi) for _ in range(11)]
    core, edge = 26, 60
    for y in range(S):
        for x in range(S):
            dx = x - H + 0.5
            dy = y - H + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            ang = math.atan2(dy, dx)
            wobble = (1.0 + 0.18 * math.sin(ang * 5)
                      + 0.12 * math.sin(ang * 9 + 0.7)
                      + 0.07 * math.sin(ang * 17))
            r_eff = r / wobble
            if r_eff < core:
                a, lum = 245, 8
            elif r_eff < edge:
                t = (r_eff - core) / float(edge - core)
                a = int(245 * (1.0 - t))
                lum = 8 + int(22 * t)
            else:
                a, lum = 0, 0
            # radial soot streaks
            if r_eff < edge * 1.25 and r > core * 0.5:
                for sa in streaks:
                    d = abs(((ang - sa + math.pi) % (2 * math.pi)) - math.pi)
                    if d < 0.06:
                        a = max(a, int(120 * (1.0 - r_eff / (edge * 1.25))))
                        lum = 14
                        break
            px[x, y] = (lum, lum, lum, max(0, min(255, a)))
    return img.filter(ImageFilter.GaussianBlur(radius=1.2))


def plasma_mark():
    """Plasma scorch — hot blue-white core fading through a dark scorch
    ring. 64px."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            if r < 6:
                px[x, y] = (180, 210, 255, 235)        # hot core
            elif r < 14:
                t = (r - 6) / 8.0
                cr = int(180 * (1 - t) + 30 * t)
                cg = int(210 * (1 - t) + 30 * t)
                cb = int(255 * (1 - t) + 45 * t)
                px[x, y] = (cr, cg, cb, int(235 * (1 - 0.3 * t)))
            elif r < 26:
                t = (r - 14) / 12.0
                px[x, y] = (30, 30, 45, max(0, int(160 * (1.0 - t))))
            else:
                px[x, y] = (0, 0, 0, 0)
    return img.filter(ImageFilter.GaussianBlur(radius=0.8))


def bfg_mark():
    """BFG energy char — sickly green with radial tendrils. 128px."""
    random.seed(0xbf61)
    S = 128
    H = S // 2
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    px = img.load()
    tendrils = [random.uniform(0, 2 * math.pi) for _ in range(9)]
    for y in range(S):
        for x in range(S):
            dx = x - H + 0.5
            dy = y - H + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            ang = math.atan2(dy, dx)
            wob = 1.0 + 0.15 * math.sin(ang * 6) + 0.10 * math.sin(ang * 13 + 0.4)
            r_eff = r / wob
            if r_eff < 22:
                a, cr, cg, cb = 230, 60, 160, 40
            elif r_eff < 56:
                t = (r_eff - 22) / 34.0
                a = int(230 * (1 - t))
                cr = int(60 * (1 - t) + 20 * t)
                cg = int(160 * (1 - t) + 50 * t)
                cb = int(40 * (1 - t) + 20 * t)
            else:
                a, cr, cg, cb = 0, 0, 0, 0
            if r_eff < 64 and a < 200 and r > 10:
                for ta in tendrils:
                    d = abs(((ang - ta + math.pi) % (2 * math.pi)) - math.pi)
                    if d < 0.05:
                        a = max(a, int(150 * (1.0 - r_eff / 64.0)))
                        cr, cg, cb = 90, 200, 60
                        break
            px[x, y] = (cr, cg, cb, max(0, min(255, a)))
    return img.filter(ImageFilter.GaussianBlur(radius=1.2))


def rail_mark():
    """Railgun slug — tight punch-through hole with a thin scorch ring.
    64px (small)."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy)
            if r < 4:
                px[x, y] = (10, 10, 12, 245)           # punch hole
            elif r < 7:
                t = (r - 4) / 3.0
                px[x, y] = (20, 20, 24, int(245 * (1 - t) + 60 * t))
            elif r < 13:
                t = (r - 7) / 6.0                       # thin scorch ring
                px[x, y] = (25, 22, 20, max(0, int(150 * (1.0 - abs(t - 0.3) / 0.7))))
            else:
                px[x, y] = (0, 0, 0, 0)
    return img.filter(ImageFilter.GaussianBlur(radius=0.6))


def shadow_blob():
    """Soft round drop-shadow for the non-stencil alias-shadow path
    (r_mesh.c blob shadow). Black RGB; smooth radial alpha falloff.
    Alpha is pre-baked at 50% max (128) so the engine uses GL_REPLACE
    and avoids any vertex-colour multiply (the Tiger ATI R9200 driver
    collapses GL_MODULATE(0,0,0,0.5 × tex) to fully transparent)."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    R = HALF - 1
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - HALF + 0.5
            dy = y - HALF + 0.5
            r = math.sqrt(dx * dx + dy * dy) / R       # 0..1
            a = 0 if r >= 1.0 else int(128 * (1.0 - r) ** 1.6)
            px[x, y] = (0, 0, 0, max(0, min(128, a)))
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
save_tga(green_blood_splat(), "greenblood")
save_tga(scorch_mark(), "scorch")
save_tga(burn_mark(), "burn")
save_tga(plasma_mark(), "plasma")
save_tga(bfg_mark(), "bfg")
save_tga(rail_mark(), "rail")
save_tga(shadow_blob(), "shadow")
print("done.")
