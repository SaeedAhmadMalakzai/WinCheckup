"""Draws the application icon (assets/WinCheckup.ico and .png).

A flat ink square with a light laptop outline and a green check on the screen.
Each size is drawn separately at 4x and scaled down, so small sizes stay sharp.
Usage: python3 tools/make_icon.py   (needs Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw

INK = (20, 32, 46, 255)
LIGHT = (232, 238, 245, 255)
GREEN = (34, 160, 80, 255)
SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
SUPERSAMPLE = 4
ROOT = Path(__file__).resolve().parent.parent


def draw(size: int) -> Image.Image:
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = round(s * 0.18)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=radius, fill=INK)

    # Thicker strokes at small sizes so the outline survives the downscale.
    stroke = max(SUPERSAMPLE * 1.5, s * (0.075 if size <= 24 else 0.055))
    stroke = round(stroke)

    # Screen
    left, right = s * 0.20, s * 0.80
    top, bottom = s * 0.22, s * 0.64
    d.rounded_rectangle((left, top, right, bottom), radius=round(s * 0.04), outline=LIGHT, width=stroke)

    # Base: a flat bar slightly wider than the screen
    base_top = bottom + s * 0.06
    d.rounded_rectangle((s * 0.12, base_top, s * 0.88, base_top + stroke * 1.2), radius=round(stroke * 0.6), fill=LIGHT)

    # Check mark inside the screen
    cx, cy = (left + right) / 2, (top + bottom) / 2
    w = (right - left) * 0.42
    points = [(cx - w * 0.50, cy + w * 0.02), (cx - w * 0.12, cy + w * 0.36), (cx + w * 0.55, cy - w * 0.36)]
    check = round(stroke * 1.25)
    d.line(points, fill=GREEN, width=check, joint="curve")
    for x, y in (points[0], points[-1]):
        r = check / 2
        d.ellipse((x - r, y - r, x + r, y + r), fill=GREEN)

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    assets = ROOT / "assets"
    assets.mkdir(exist_ok=True)
    frames = [draw(size) for size in SIZES]
    largest = frames[-1]
    # BMP entries: NSIS and every Windows version read them.
    largest.save(assets / "WinCheckup.ico", format="ICO", sizes=[(n, n) for n in SIZES],
                 append_images=frames[:-1], bitmap_format="bmp")
    largest.save(assets / "WinCheckup.png")
    print("written:", assets / "WinCheckup.ico")


if __name__ == "__main__":
    main()
