#!/usr/bin/env python3
"""Generate the Julia Gym app icon: the three Julia dots on a rounded square.

The same motif the progress rail uses for a clean solve, so the Dock icon and
the app agree with each other.
"""
from PIL import Image, ImageDraw
import os, subprocess

RED, GREEN, PURPLE = (0xCB, 0x3C, 0x33), (0x38, 0x98, 0x26), (0x95, 0x58, 0xB2)
BG = (0x1F, 0x19, 0x26)          # the app's dark surface — reads on any Dock

SS = 8                            # supersample factor for smooth edges

def render(size):
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # macOS-style rounded square, inset slightly like a real app icon.
    pad = int(S * 0.055)
    d.rounded_rectangle([pad, pad, S - pad, S - pad],
                        radius=int(S * 0.2237), fill=BG + (255,))

    # Three dots in the Julia arrangement: purple up top, red and green below.
    r  = S * 0.132
    cx, cy = S / 2, S / 2
    dx = S * 0.158
    dy = S * 0.140
    for (x, y, c) in ((cx,      cy - dy * 1.05, PURPLE),
                      (cx - dx, cy + dy,        RED),
                      (cx + dx, cy + dy,        GREEN)):
        d.ellipse([x - r, y - r, x + r, y + r], fill=c + (255,))

    return img.resize((size, size), Image.LANCZOS)

out = os.path.join(os.path.dirname(__file__), "JuliaGym.iconset")
os.makedirs(out, exist_ok=True)
for base in (16, 32, 128, 256, 512):
    render(base).save(f"{out}/icon_{base}x{base}.png")
    render(base * 2).save(f"{out}/icon_{base}x{base}@2x.png")
print("iconset written:", out)
