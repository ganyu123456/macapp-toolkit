#!/usr/bin/env python3
"""Generate app icon for 工具箱.app"""
import os, math
from PIL import Image, ImageDraw

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon.iconset")
os.makedirs(OUTPUT_DIR, exist_ok=True)

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def create_icon(size):
    """Create a single icon image at given pixel size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rectangle background with gradient-like solid colors
    m = max(1, size * 0.06)  # margin
    r = int(size * 0.22)      # corner radius

    # Draw background rounded rect (blue gradient approximation)
    draw.rounded_rectangle(
        [(m, m), (size - m, size - m)],
        radius=r,
        fill=(40, 104, 220, 255)
    )

    # Inner lighter rounded rect for depth
    inner_m = size * 0.13
    inner_r = int(size * 0.18)
    draw.rounded_rectangle(
        [(inner_m, inner_m), (size - inner_m, size - inner_m)],
        radius=inner_r,
        fill=(55, 120, 235, 255)
    )

    # Draw a gear/wrench symbol in white
    cx, cy = size / 2, size / 2
    scale = size / 1024.0

    # Gear parameters
    outer_r = size * 0.3
    inner_r = size * 0.22
    tooth_w = size * 0.05
    tooth_l = size * 0.06
    center_hole = size * 0.09

    # Draw gear
    num_teeth = 8
    for i in range(num_teeth):
        angle = (2 * math.pi * i) / num_teeth
        # Tooth position (centered on the rim)
        rim_r = outer_r - tooth_l * 0.4
        tx = cx + rim_r * math.cos(angle)
        ty = cy + rim_r * math.sin(angle)

        # Draw tooth as a small rounded rectangle
        draw.rounded_rectangle(
            [
                (tx - tooth_w / 2, ty - tooth_l / 2),
                (tx + tooth_w / 2, ty + tooth_l / 2),
            ],
            radius=int(size * 0.02),
            fill=(255, 255, 255, 255),
        )

    # Draw outer ring
    draw.ellipse(
        [
            (cx - outer_r, cy - outer_r),
            (cx + outer_r, cy + outer_r),
        ],
        fill=(255, 255, 255, 255),
    )

    # Cut out inner circle (draw in background color)
    draw.ellipse(
        [
            (cx - inner_r, cy - inner_r),
            (cx + inner_r, cy + inner_r),
        ],
        fill=(55, 120, 235, 255),
    )

    # Center bolt
    draw.ellipse(
        [
            (cx - center_hole, cy - center_hole),
            (cx + center_hole, cy + center_hole),
        ],
        fill=(255, 255, 255, 255),
    )

    # Small accent dot in bolt
    accent = size * 0.025
    draw.ellipse(
        [
            (cx - accent, cy - accent),
            (cx + accent, cy + accent),
        ],
        fill=(55, 120, 235, 255),
    )

    return img


# Generate icons at all required sizes
for size in SIZES:
    img = create_icon(size)
    if size <= 32:
        name = f"icon_{size}x{size}.png"
    else:
        name = f"icon_{size // 2}x{size // 2}@2x.png"
        # Standard icon
        img.save(os.path.join(OUTPUT_DIR, name), "PNG")

    if size == 1024:
        img.save(os.path.join(OUTPUT_DIR, "icon_512x512@2x.png"), "PNG")

    if size >= 64:
        half = size // 2
        half_img = img.resize((half, half), Image.LANCZOS)
        half_name = f"icon_{half // 2}x{half // 2}.png"
        if size == 64:
            half_img.save(os.path.join(OUTPUT_DIR, half_name), "PNG")
        elif size == 128:
            half_img.save(os.path.join(OUTPUT_DIR, "icon_32x32@2x.png"), "PNG")
        elif size == 256:
            half_img.save(os.path.join(OUTPUT_DIR, "icon_64x64@2x.png"), "PNG")
        elif size == 512:
            half_img.save(os.path.join(OUTPUT_DIR, "icon_128x128@2x.png"), "PNG")
            half2 = half_img.resize((128, 128), Image.LANCZOS)
            half2.save(os.path.join(OUTPUT_DIR, "icon_128x128.png"), "PNG")
            half3 = half_img.resize((256, 256), Image.LANCZOS)
            half3.save(os.path.join(OUTPUT_DIR, "icon_256x256@2x.png"), "PNG")
        elif size == 1024:
            half_img.save(os.path.join(OUTPUT_DIR, "icon_256x256@2x.png"), "PNG")
            half2 = half_img.resize((256, 256), Image.LANCZOS)
            half2.save(os.path.join(OUTPUT_DIR, "icon_256x256.png"), "PNG")
            half3 = half_img.resize((512, 512), Image.LANCZOS)
            half3.save(os.path.join(OUTPUT_DIR, "icon_512x512@2x.png"), "PNG")

print(f"Icon PNGs generated in {OUTPUT_DIR}")
