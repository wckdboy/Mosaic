#!/usr/bin/env python3
"""Reproduce the original five-tile Mosaic icon and its dark appearance.

The geometry is the original design, recovered from this project's creation
history. Keep SVG and the Xcode PNG assets together when editing the mark.
"""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Mosaic/Assets.xcassets/AppIcon.appiconset"
TILES = [((212, 212, 592, 592), 54), ((624, 212, 812, 392), 38),
         ((624, 424, 812, 592), 38), ((212, 624, 392, 812), 38),
         ((424, 624, 812, 812), 42)]
ASSETS.mkdir(parents=True, exist_ok=True)
for filename, background, foreground in [("AppIcon.png", "white", "black"),
                                         ("AppIcon-dark.png", "black", "white")]:
    image = Image.new("RGB", (1024, 1024), background)
    draw = ImageDraw.Draw(image)
    for rectangle, radius in TILES:
        draw.rounded_rectangle(rectangle, radius, fill=foreground)
    image.save(ASSETS / filename)
svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n<title>Mosaic — five tiles</title>\n<rect width="1024" height="1024" fill="white"/>\n'
for (x, y, right, bottom), radius in TILES:
    svg += f'<rect x="{x}" y="{y}" width="{right-x}" height="{bottom-y}" rx="{radius}" fill="black"/>\n'
(ROOT / "docs/mosaic-icon.svg").write_text(svg + '</svg>\n')
(ASSETS / "Contents.json").write_text(json.dumps({"images": [
    {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    {"filename": "AppIcon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024", "appearances": [{"appearance": "luminosity", "value": "dark"}]},
], "info": {"author": "xcode", "version": 1}}, indent=2) + '\n')
