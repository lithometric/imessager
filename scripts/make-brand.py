#!/usr/bin/env python3
"""Builds every logo asset from the brand sheet (Support/Brand/imessager-brand.png).

The sheet's layout is fixed (icon left, light and dark wordmarks right); positions below are for the 1200x600 1x
sheet and scale to whatever size the sheet is (the 2400x1200 @2x sheet gives a ~940 px icon). Rather than upscaling pixels, this lifts the
white bubble out as a mask, upscales the mask, re-thresholds it (smooth, vector-like edges), and redraws the
blue tile at full resolution. Output:

  Support/AppIcon.icns                  app icon (Dock, Finder, About, notifications)
  Support/Brand/AppIcon-1024.png        same, for the README
  Support/Brand/MenuBarIcon(@2x).png    menu bar template (black glyph)
  Support/Brand/Bubble(@2x).png         the bubble alone, white template (tinted in the app)
  Support/Brand/Wordmark(@2x).png       "imessager" wordmark, black template (tinted in the app)

Needs Pillow. Run from the repo root: python3 scripts/make-brand.py
"""
import os
import random
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SHEET = "Support/Brand/imessager-brand.png"
OUT = "Support/Brand"

# Where things sit on the 1x sheet; scaled to the actual sheet in main().
TILE = (64, 65, 535, 535)          # rounded blue tile
GLYPH_BOX = (100, 100, 500, 500)   # area inside the tile that holds the bubble (clear of the rounded corners)
WORDMARK = (733, 144, 1040, 213)   # "imessager" text on the light card

# Tile color: flat Messages green, top to bottom. (sample_stops() can take a gradient from the sheet instead.)
GREEN = (52, 199, 89)
STOPS = [(0.0, GREEN), (1.0, GREEN)]


def scale_layout(sheet):
    global TILE, GLYPH_BOX, WORDMARK
    s = sheet.width / 1200
    TILE, GLYPH_BOX, WORDMARK = (tuple(round(v * s) for v in box) for box in (TILE, GLYPH_BOX, WORDMARK))


def sample_stops(sheet):
    """Average a small patch near the tile's left edge (clear of the bubble) at the top, middle and bottom."""
    global STOPS
    rgb = sheet.convert("RGB")
    x0, y0, x1, y1 = TILE
    w, h = x1 - x0, y1 - y0
    patch = max(3, w // 60)

    def avg(fy):
        x, y = x0 + int(w * 0.12), y0 + int(h * fy)
        px = [rgb.getpixel((x + dx, y + dy)) for dx in range(patch) for dy in range(patch)]
        return tuple(round(sum(c[i] for c in px) / len(px)) for i in range(3))

    STOPS = [(0.0, avg(0.07)), (0.5, avg(0.5)), (1.0, avg(0.93))]


def glyph_mask(sheet):
    """White bubble from the blue tile as an L mask, using each row's blue as the reference."""
    rgb = sheet.convert("RGB")
    x0, y0, x1, y1 = GLYPH_BOX
    mask = Image.new("L", (x1 - x0, y1 - y0), 0)
    out = mask.load()
    src = rgb.load()
    for y in range(y0, y1):
        reds = sorted(src[x, y][0] for x in range(TILE[0] + 20, TILE[2] - 20, 2) if src[x, y][2] - src[x, y][0] > 100)
        bg = reds[len(reds) // 2] if reds else 40
        for x in range(x0, x1):
            r = src[x, y][0]
            out[x - x0, y - y0] = max(0, min(255, round((r - bg) * 255 / max(1, 255 - bg))))
    return mask


def text_mask(sheet):
    """Dark wordmark on the light card as an L mask."""
    crop = sheet.convert("L").crop(WORDMARK)
    return crop.point(lambda v: max(0, min(255, round((255 - v) * 255 / 245))))


def smooth_scale(mask, scale):
    """Upscale a mask with clean edges: bicubic at 4x the target, threshold, then box down."""
    w, h = mask.size
    big = mask.resize((max(1, round(w * scale * 4)), max(1, round(h * scale * 4))), Image.BICUBIC)
    big = big.point(lambda v: 255 if v >= 128 else 0)
    return big.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)


def gradient(size):
    w, h = size
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
            if t0 <= t <= t1:
                f = (t - t0) / (t1 - t0)
                px[0, y] = tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
                break
    img = img.resize((w, h))
    # The sheet's tile has a faint grain; match it so the gradient doesn't band.
    random.seed(7)
    noise = Image.frombytes("L", (w, h), bytes(random.randint(124, 132) for _ in range(w * h)))
    return ImageChops.add(img, Image.merge("RGB", (noise,) * 3), 1, -128)


def app_icon(glyph):
    """1024 px macOS icon: 824 px rounded tile with a soft shadow, bubble redrawn at full size."""
    size, body, inset = 1024, 824, 100
    radius = round(body * 0.2237)
    ss = 4
    shape = Image.new("L", (body * ss, body * ss), 0)
    ImageDraw.Draw(shape).rounded_rectangle((0, 0, body * ss - 1, body * ss - 1), radius=radius * ss, fill=255)
    shape = shape.resize((body, body), Image.LANCZOS)

    tile = gradient((body, body)).convert("RGBA")
    scale = body / (TILE[2] - TILE[0])
    bubble = smooth_scale(glyph, scale)
    offset = (round((GLYPH_BOX[0] - TILE[0]) * scale), round((GLYPH_BOX[1] - TILE[1]) * scale))
    white = Image.new("RGBA", bubble.size, (255, 255, 255, 255))
    tile.paste(white, offset, bubble)
    tile.putalpha(shape)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (body, body), (0, 0, 0, 80)), (inset, inset + 12), shape)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(18)))
    canvas.alpha_composite(tile, (inset, inset))
    return canvas


def fitted(glyph, px, pad, color):
    """The bubble alone, centered in a px-square canvas, as a solid-color template."""
    box = glyph.point(lambda v: 255 if v > 60 else 0).getbbox()
    g = glyph.crop(box)
    scale = (px - 2 * pad) / max(g.size)
    g = smooth_scale(g, scale)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    solid = Image.new("RGBA", g.size, color)
    out.paste(solid, ((px - g.width) // 2, (px - g.height) // 2), g)
    return out


def template(mask, height, color):
    scale = height / mask.height
    m = smooth_scale(mask, scale)
    out = Image.new("RGBA", m.size, (0, 0, 0, 0))
    out.paste(Image.new("RGBA", m.size, color), (0, 0), m)
    return out


def main():
    sheet = Image.open(SHEET)
    scale_layout(sheet)
    print("tile colors:", STOPS)
    glyph = glyph_mask(sheet)
    text = text_mask(sheet)

    icon = app_icon(glyph)
    icon.save(f"{OUT}/AppIcon-1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for pt in (16, 32, 128, 256, 512):
            for mult in (1, 2):
                name = f"icon_{pt}x{pt}{'@2x' if mult == 2 else ''}.png"
                icon.resize((pt * mult, pt * mult), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "Support/AppIcon.icns"], check=True)

    fitted(glyph, 18, 1, (0, 0, 0, 255)).save(f"{OUT}/MenuBarIcon.png")
    fitted(glyph, 36, 2, (0, 0, 0, 255)).save(f"{OUT}/MenuBarIcon@2x.png")
    fitted(glyph, 64, 0, (255, 255, 255, 255)).save(f"{OUT}/Bubble.png")
    fitted(glyph, 128, 0, (255, 255, 255, 255)).save(f"{OUT}/Bubble@2x.png")
    template(text, 22, (0, 0, 0, 255)).save(f"{OUT}/Wordmark.png")
    template(text, 44, (0, 0, 0, 255)).save(f"{OUT}/Wordmark@2x.png")
    print("Wrote Support/AppIcon.icns and Support/Brand/*.png")


if __name__ == "__main__":
    main()
