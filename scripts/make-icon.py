#!/usr/bin/env python3
"""
Generate AIPointer app icon and menu bar icon.
App icon: black background, white cursor + sparkle
Menu bar: white cursor on transparent (template image)
"""

from PIL import Image, ImageDraw
import os, math

# --- Cursor polygon (1024x1024 canvas) ---
# Classic Mac arrow cursor pointing up-left
BASE_PTS = [
    (312, 172),   # tip
    (312, 732),   # bottom-left (stem)
    (472, 612),   # notch inner-left
    (592, 852),   # stem bottom point
    (672, 812),   # stem bottom-right
    (552, 572),   # notch inner-right
    (712, 572),   # arrowhead top-right
]

def scale_pts(pts, size):
    s = size / 1024
    return [(x * s, y * s) for x, y in pts]

def draw_sparkle(draw, cx, cy, r, color):
    """4-pointed star sparkle."""
    pts = []
    for i in range(16):
        angle = math.pi * 2 * i / 16 - math.pi / 2
        radius = r if i % 4 == 0 else r * 0.28
        pts.append((cx + math.cos(angle) * radius,
                    cy + math.sin(angle) * radius))
    draw.polygon(pts, fill=color)

def make_app_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    draw = ImageDraw.Draw(img)

    pts = scale_pts(BASE_PTS, size)
    draw.polygon(pts, fill=(255, 255, 255, 255))

    # Sparkle near top-right
    s = size / 1024
    draw_sparkle(draw, 790 * s, 210 * s, 72 * s, (255, 255, 255, 255))

    return img

def make_menubar_icon(size):
    """White cursor on transparent background (template image)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    pts = scale_pts(BASE_PTS, size)
    draw.polygon(pts, fill=(0, 0, 0, 255))
    return img

# --- Output dirs ---
script_dir = os.path.dirname(os.path.abspath(__file__))
project_dir = os.path.dirname(script_dir)
resources_dir = os.path.join(project_dir, "AIPointer", "Resources")
iconset_dir = os.path.join(project_dir, "dist", "AppIcon.iconset")
os.makedirs(iconset_dir, exist_ok=True)

# --- App icon sizes ---
icon_sizes = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for size, name in icon_sizes:
    img = make_app_icon(size)
    img.save(os.path.join(iconset_dir, name))
    print(f"  {name}")

# --- Menu bar template icons ---
for size, name in [(18, "menubar.png"), (36, "menubar@2x.png")]:
    img = make_menubar_icon(size)
    img.save(os.path.join(resources_dir, name))
    print(f"  Resources/{name}")

print("Done.")
