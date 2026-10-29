"""Draws the ProxyShare app icon: a phone broadcasting its connection.

Usage: python Tools/make_icon.py <output.png>
"""
import sys

from PIL import Image, ImageDraw

SCALE = 4  # draw large, then downsample for smooth edges
SIZE = 1024 * SCALE
TOP = (11, 61, 145)      # deep blue
BOTTOM = (19, 181, 166)  # teal
WHITE = (255, 255, 255)


def gradient(size):
    # Diagonal blend from the top-left to the bottom-right corner.
    small = Image.new("RGB", (256, 256))
    pixels = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            pixels[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return small.resize((size, size), Image.BICUBIC)


def s(value):
    return round(value * SCALE)


def main(path):
    icon = gradient(SIZE)
    draw = ImageDraw.Draw(icon)

    # Phone body, slightly below centre.
    left, top, right, bottom = s(372), s(430), s(652), s(880)
    draw.rounded_rectangle((left, top, right, bottom), radius=s(56), outline=WHITE, width=s(34))
    draw.rounded_rectangle((s(472), s(470), s(552), s(486)), radius=s(8), fill=WHITE)  # speaker slot
    draw.ellipse((s(492), s(776), s(532), s(816)), fill=WHITE)  # home dot

    # Broadcast arcs above the phone.
    cx, cy = s(512), s(400)
    for radius in (90, 175, 260):
        r = s(radius)
        draw.arc((cx - r, cy - r, cx + r, cy + r), start=228, end=312, fill=WHITE, width=s(38))

    icon.resize((1024, 1024), Image.LANCZOS).save(path, "PNG")


if __name__ == "__main__":
    main(sys.argv[1])
