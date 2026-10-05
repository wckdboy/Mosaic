#!/usr/bin/env python3
"""Create synthetic, non-personal image/GIF fixtures for simulator verification.

Usage: python3 scripts/make-test-media.py /tmp/mosaic-media
Requires Pillow. The generated assets are test data, not bundled app content.
"""
import pathlib
import sys
from PIL import Image, ImageDraw

output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/mosaic-media")
output.mkdir(parents=True, exist_ok=True)
colors = [(49, 93, 105), (211, 147, 89), (74, 78, 60), (124, 104, 148)]
for index, color in enumerate(colors):
    image = Image.new("RGB", (1200, 900), color)
    draw = ImageDraw.Draw(image)
    for layer in range(5):
        x = 100 + layer * 200
        draw.ellipse((x, 200 + layer * 70, x + 340, 900), fill=tuple(min(255, c + layer * 12) for c in color))
    draw.text((80, 80), f"MOSAIC TEST {index + 1} — COPENHAGEN 2026", fill="white", font_size=38)
    image.save(output / f"sample-{index + 1}.jpg")
frames = []
for frame in range(16):
    image = Image.new("RGB", (640, 480), (20, 20, 20))
    draw = ImageDraw.Draw(image)
    x = 30 + frame * 30
    draw.ellipse((x, 160, x + 100, 260), fill=(250, 148, 41))
    draw.text((30, 35), "ANIMATION TEST", fill="white", font_size=28)
    frames.append(image)
frames[0].save(output / "motion.gif", save_all=True, append_images=frames[1:], duration=70, loop=0)
print(output)
