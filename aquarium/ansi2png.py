#!/usr/bin/env python3
"""Convert the aquarium's ANSI half-block frame to a PNG for visual inspection."""
import re
import struct
import sys
import zlib

SCALE = 8

def parse_ansi(data: bytes):
    text = data.decode("utf-8")
    fg = bg = None
    pixels = {}  # (row, col) -> (top_rgb, bottom_rgb)
    row = col = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\x1b":
            m = re.match(r"\x1b\[([0-9;]*)m", text[i:])
            if m:
                codes = m.group(1).split(";")
                j = 0
                while j < len(codes):
                    c = codes[j]
                    if c == "0":
                        fg = bg = None
                    elif c == "38" and j + 1 < len(codes) and codes[j + 1] == "2":
                        fg = tuple(int(codes[j + 2 + k]) for k in range(3))
                        j += 4
                    elif c == "48" and j + 1 < len(codes) and codes[j + 1] == "2":
                        bg = tuple(int(codes[j + 2 + k]) for k in range(3))
                        j += 4
                    j += 1
                i += m.end()
                continue
            m = re.match(r"\x1b\[[?0-9]*[A-Za-z]", text[i:])
            if m:
                i += m.end()
                continue
            i += 1
            continue
        if ch == "\n":
            row += 1
            col = 0
        elif ch not in "▀▄ " and ch.isprintable():
            # text cell (e.g. the crab's label): bg with a fg glyph-ish blob
            pixels[(row, col)] = (bg, bg, fg)
            col += 1
        elif ch in "▀▄ ":
            if ch == "▀":
                top, bot = fg, bg
            elif ch == "▄":
                top, bot = bg, fg
            else:
                top = bot = bg
            pixels[(row, col)] = (top, bot)
            col += 1
        # ignore anything else
        i += 1
    return pixels

def main():
    src, dst = sys.argv[1], sys.argv[2]
    pixels = parse_ansi(open(src, "rb").read())
    rows = max(r for r, c in pixels) + 1
    cols = max(c for r, c in pixels) + 1
    W, H = cols * SCALE, rows * 2 * SCALE
    img = bytearray(W * H * 3)
    for (r, c), cell in pixels.items():
        top, bot = cell[:2]
        for half, rgb in ((0, top), (1, bot)):
            if rgb is None:
                rgb = (12, 12, 16)
            for dy in range(SCALE):
                y = (r * 2 + half) * SCALE + dy
                for dx in range(SCALE):
                    x = c * SCALE + dx
                    o = (y * W + x) * 3
                    img[o:o + 3] = bytes(rgb)
        if len(cell) == 3 and cell[2]:
            for y in range(r * 2 * SCALE + 4, (r * 2 + 2) * SCALE - 3):
                for x in range(c * SCALE + 2, (c + 1) * SCALE - 2):
                    if (x + y) % 3:
                        o = (y * W + x) * 3
                        img[o:o + 3] = bytes(cell[2])
    raw = b""
    stride = W * 3
    for y in range(H):
        raw += b"\x00" + bytes(img[y * stride:(y + 1) * stride])
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    open(dst, "wb").write(png)
    print(f"{dst}: {W}x{H}")

if __name__ == "__main__":
    main()
