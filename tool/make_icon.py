"""Draws the Marsa app icon and writes the macOS and Windows icon files.

    python3 tool/make_icon.py        # needs Pillow

Everything is drawn from the shapes below, so the icon has no source image to
keep in sync: change the colours or geometry here and run it again.
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN = ROOT / "windows/runner/resources/app_icon.ico"

SS = 4  # supersampling factor for smooth edges
TOP, BOTTOM = (45, 212, 191), (13, 116, 110)  # teal gradient
MARK = (255, 255, 255)


def gradient(size):
    col = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        col.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return col.resize((size, size))


def anchor(size):
    """White anchor on transparent, drawn in a 1000-unit box scaled to size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = size / 1000

    def line(x1, y1, x2, y2, w):
        d.line([(x1 * k, y1 * k), (x2 * k, y2 * k)], fill=MARK, width=round(w * k))
        r = w * k / 2
        for x, y in ((x1, y1), (x2, y2)):
            d.ellipse([x * k - r, y * k - r, x * k + r, y * k + r], fill=MARK)

    # ring
    d.ellipse([(500 - 78) * k, (212 - 78) * k, (500 + 78) * k, (212 + 78) * k],
              outline=MARK, width=round(46 * k))
    line(500, 290, 500, 770, 60)   # shank
    line(360, 400, 640, 400, 56)   # stock
    # arms: the lower part of a circle around the shank
    r = 250
    d.arc([(500 - r) * k, (520 - r) * k, (500 + r) * k, (520 + r) * k],
          start=12, end=168, fill=MARK, width=round(60 * k))
    # flukes
    for s in (-1, 1):
        x = 500 + s * 222
        d.polygon([((x - 78) * k, 600 * k), ((x + 78) * k, 600 * k),
                   ((x + s * 18) * k, 462 * k)], fill=MARK)
    return img


def tile(size, inset, radius, shadow):
    """The rounded gradient square with the anchor, on a size x size canvas."""
    big = size * SS
    box = [inset * SS, inset * SS, big - inset * SS, big - inset * SS]
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius * SS, fill=255)

    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    if shadow:
        soft = ImageChops.offset(mask, 0, round(size * 0.012 * SS))
        soft = soft.filter(ImageFilter.GaussianBlur(size * 0.016 * SS))
        out.paste((0, 0, 0, 90), mask=soft)

    side = big - 2 * inset * SS
    face = gradient(side).convert("RGBA")
    face.alpha_composite(anchor(side))
    out.paste(face, (inset * SS, inset * SS), mask.crop(box))
    return out.resize((size, size), Image.LANCZOS)


def main():
    # macOS: Apple's template leaves a margin around an 824 px rounded square.
    mac = tile(1024, inset=100, radius=185, shadow=True)
    for s in (16, 32, 64, 128, 256, 512, 1024):
        mac.resize((s, s), Image.LANCZOS).save(MAC / f"app_icon_{s}.png")

    # Windows: the tile fills the whole icon.
    win = tile(1024, inset=0, radius=230, shadow=False)
    win.save(WIN, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    print("wrote", MAC, "and", WIN)


if __name__ == "__main__":
    main()
