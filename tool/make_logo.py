"""Generates the Verbal Outlet app icon.

The mark is two filled seas on a dark navy rounded tile: a deep ocean blue
behind, a bright cyan sea in front, with a pale glint running along the front
waterline. Two overlapping waterlines read as depth, and the curve of a swell
reads as a sound wave, which suits a voice diary.

Geometry is the "two seas" concept picked from the exploration sheet
(tool/logo_options.py, opt_waterline): the same wave function, same phases and
same palette, so the icon matches what was chosen.

Run from the project root:

    python tool/make_logo.py

Outputs:
    assets/branding/icon_1024.png         master, dark rounded tile
    assets/branding/mark_transparent.png  water only, no navy backdrop
    windows/runner/resources/app_icon.ico
    android/app/src/main/res/mipmap-*/ic_launcher.png
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

# --- Palette, matching lib/theme.dart -------------------------------------
ABYSS_TOP = (14, 28, 46)
ABYSS_BOTTOM = (7, 15, 27)
DEEP_HI = (54, 141, 168)
DEEP_LO = (25, 80, 102)
FRONT = (95, 211, 232)
FRONT_LO = (36, 140, 170)
FRONT_HI = (152, 235, 248)
INK = (4, 9, 16)

SIZE = 1024
SS = 3  # supersampling factor
CORNER_RADIUS = 0.225  # of the tile side


# --- Toolkit --------------------------------------------------------------


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _vgrad(size, top, bottom):
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        px[0, y] = _lerp(top, bottom, y / max(1, size - 1))
    return strip.resize((size, size))


def _paint(canvas, mask, style):
    """Composites a flat colour or a vertical gradient through a mask."""
    if isinstance(style, tuple) and style and isinstance(style[0], str):
        axis, c0, c1 = style
        tile = _vgrad(canvas.width, c0, c1)
        layer = tile.convert("RGBA")
    else:
        layer = Image.new("RGBA", canvas.size, tuple(style) + (255,))
    layer.putalpha(mask)
    canvas.alpha_composite(layer)


def _soft_shadow(canvas, mask, offset_y, blur, alpha, colour=INK):
    shadow = mask.filter(ImageFilter.GaussianBlur(blur))
    shadow = ImageChops.offset(shadow, 0, int(offset_y))
    layer = Image.new("RGBA", canvas.size, tuple(colour) + (0,))
    layer.putalpha(shadow.point(lambda v: int(v * alpha)))
    canvas.alpha_composite(layer)


def _wave(size, x0, x1, cy, amp, *, phase=0.0, steps=520):
    """A wave that starts and ends low: trough -> crest -> trough.

    Screen y grows downwards, so `cy + amp` is the low point and `cy - amp` the
    high one. Phase 0 puts a trough at each end.
    """
    points = []
    for i in range(steps + 1):
        t = i / steps
        x = (x0 + (x1 - x0) * t) * size
        y = (cy + amp * math.cos(2 * math.pi * t + phase)) * size
        points.append((x, y))
    return points


def _fill_below(size, points):
    """Everything under a path, out to the tile edges."""
    polygon = list(points) + [(points[-1][0], size), (points[0][0], size)]
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    return mask


def _stroke(size, points, thickness):
    """A smooth band along a path.

    Stamped as overlapping discs: stroking a long polyline at large widths
    hatches, and offset polygons leave lumps where the curve turns tightly.
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = thickness / 2
    for x, y in points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
    return mask


def _rounded_mask(size):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1),
        radius=int(size * CORNER_RADIUS),
        fill=255,
    )
    return mask


def _background(size):
    """Vertical gradient inside a rounded square."""
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile.paste(_vgrad(size, ABYSS_TOP, ABYSS_BOTTOM).convert("RGBA"),
               (0, 0), _rounded_mask(size))
    return tile


# --- The mark -------------------------------------------------------------


def _draw_waves(work, canvas):
    """Paints the two seas and the glint onto `canvas`.

    The back sea sits higher and deeper; the front sea is brighter and lower,
    so it overlaps the back one and the pair read as one swell with depth.
    """
    back = _wave(work, -0.05, 1.05, 0.400, 0.085, phase=0.35)
    _paint(canvas, _fill_below(work, back), ("v", DEEP_HI, DEEP_LO))

    front = _wave(work, -0.05, 1.05, 0.610, 0.085, phase=-0.55)
    front_mask = _fill_below(work, front)
    _soft_shadow(canvas, front_mask, -0.012 * work, 0.020 * work, 0.40)
    _paint(canvas, front_mask, ("v", FRONT, FRONT_LO))

    # A pale glint just under the front waterline, clipped to the water so it
    # cannot spill into the sky.
    glint_path = [(x, y + 0.024 * work) for x, y in front]
    glint = ImageChops.multiply(
        _stroke(work, glint_path, 0.026 * work), front_mask
    )
    _paint(canvas, glint, FRONT_HI)
    return front_mask


def draw_mark(size, *, background=True):
    """Renders the mark at `size` pixels."""
    work = size * SS

    if background:
        canvas = _background(work)
    else:
        canvas = Image.new("RGBA", (work, work), (0, 0, 0, 0))

    front_mask = _draw_waves(work, canvas)

    img = canvas.resize((size, size), Image.LANCZOS)

    if background:
        # Re-apply the tile mask after resizing, to keep crisp corners.
        img.putalpha(_rounded_mask(size))
    else:
        # Without the navy tile, the water would otherwise fill a square of its
        # own; clipping it to the same rounded shape keeps the mark a tile on
        # any backdrop.
        tile_mask = _rounded_mask(size)
        alpha = ImageChops.multiply(img.getchannel("A"), tile_mask)
        img.putalpha(alpha)
    return img


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    branding = os.path.join(root, "assets", "branding")
    os.makedirs(branding, exist_ok=True)

    tile = draw_mark(SIZE)
    tile.save(os.path.join(branding, "icon_1024.png"))
    print("wrote assets/branding/icon_1024.png")

    mark = draw_mark(SIZE, background=False)
    mark.save(os.path.join(branding, "mark_transparent.png"))
    print("wrote assets/branding/mark_transparent.png")

    # --- Windows .ico, multi-resolution ---
    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    ico_images = [
        tile.resize((s, s), Image.LANCZOS) for s in ico_sizes
    ]
    ico_path = os.path.join(
        root, "windows", "runner", "resources", "app_icon.ico"
    )
    ico_images[-1].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=ico_images[:-1],
    )
    print("wrote windows/runner/resources/app_icon.ico")

    # --- Android launcher icons ---
    android = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android.items():
        out_dir = os.path.join(
            root, "android", "app", "src", "main", "res", folder
        )
        os.makedirs(out_dir, exist_ok=True)
        tile.resize((size, size), Image.LANCZOS).save(
            os.path.join(out_dir, "ic_launcher.png")
        )
        print(f"wrote android/.../{folder}/ic_launcher.png")


if __name__ == "__main__":
    main()
