#!/usr/bin/env python3
"""
Draw the app icon and build Substrate.icns.

The mark is the pill: a row of dots where one is amber. That is already the
thing in the menu bar, and an icon that is a picture of something else would
be a second identity to maintain. Motion means state, colour means exception,
so the icon shows the one moment that matters: something needs a person.

    python3 make-icon.py            writes Substrate.icns next to this file

Needs Pillow. Everything else is macOS's own iconutil.
"""

import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("this needs Pillow:  python3 -m pip install pillow")

HERE = Path(__file__).parent
SIZE = 1024

GROUND = (26, 26, 27, 255)      # the dark ground the dots sit on
# Opaque, not translucent. A see-through dot drawn on a transparent canvas
# keeps its alpha all the way to the Dock, where it lands on whatever is
# behind the icon and reads as white. This is the same grey, worked out
# against the ground once, here.
DIM = (106, 106, 107, 255)      # idle: present, not asking for anything
AMBER = (217, 166, 38, 255)     # needs you, the one exception


def draw(px=SIZE):
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = px / 1024

    # macOS rounded square, inset the way the platform's own icons are, so it
    # sits at the same visual size as everything else in the Dock.
    inset, radius = 100 * u, 185 * u
    d.rounded_rectangle([inset, inset, px - inset, px - inset],
                        radius=radius, fill=GROUND)

    # Four dots, centred. The third is the one asking.
    dot, gap = 118 * u, 62 * u
    total = dot * 4 + gap * 3
    x = (px - total) / 2
    y = px / 2 - dot / 2
    for i in range(4):
        colour = AMBER if i == 2 else DIM
        d.ellipse([x, y, x + dot, y + dot], fill=colour)
        x += dot + gap
    return img


def main():
    if not shutil.which("iconutil"):
        sys.exit("iconutil is missing, so this only runs on macOS")
    iconset = HERE / "Substrate.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()

    # Every size macOS asks for, drawn rather than scaled, so the dots keep
    # their edges at 16 points as well as at 512.
    for px in (16, 32, 64, 128, 256, 512, 1024):
        img = draw(px)
        if px <= 512:
            img.save(iconset / f"icon_{px}x{px}.png")
        if px >= 32:
            img.save(iconset / f"icon_{px // 2}x{px // 2}@2x.png")

    out = HERE / "Substrate.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)],
                   check=True)
    shutil.rmtree(iconset)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
