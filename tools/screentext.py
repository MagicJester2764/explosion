#!/usr/bin/env python3
"""Read a screenshot of the text console back as text.

    tools/screentext.py <shot.ppm> [font.rs]

The console draws a bitmap font on a grid, so a screendump of it *is* its
text, exactly: each cell is matched against the fonts it may have been drawn
with. One is built into the console (`quark-rt/src/font.rs` in the userland,
or `QUARK_FONT`), and is ASCII. The other is whatever `setfont` loaded, in
GNU Unifont's `.hex` format: name the file, or several with the path
separator between them, in `QUARK_FONT_HEX`, and a screen drawn in it is read
too — including the characters that are two cells wide.

A cell is decided by which of its pixels differ from its most common colour,
so neither the colour a program printed in nor a background behind it
matters. A cell that matches nothing — part of a window, a picture, a
character no font here has — is `?`. Where two characters have the same
shape, as a Latin A and a Greek one do, it is read as the one that comes
first.

It is what lets a test wait for a prompt rather than for a number of seconds,
and what turns "look at the screenshot" into something `grep` can do.
"""
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.environ.get(
    "QUARK_FONT",
    os.path.join(HERE, "..", "..", "quarkutils", "quark-rt", "src", "font.rs"))
GLYPH_W, GLYPH_H = 8, 16


class Font:
    """Glyph bitmaps to the character each is: one cell wide, and two."""

    def __init__(self):
        self.narrow = {}
        self.wide = {}

    def add(self, rows, char):
        # The first character to claim a shape keeps it, so blank is a space.
        (self.wide if len(rows) == 2 * GLYPH_H else self.narrow).setdefault(rows, char)


def load_font(path=FONT, hex_paths=None):
    """The fonts a screen may be drawn in: the console's own, from the Rust
    table, and any `.hex` files named."""
    font = Font()
    rows = re.findall(r"\[((?:0x[0-9A-Fa-f]{2},?){16})\]", open(path).read())
    for code, row in enumerate(rows[:128]):
        key = tuple(int(b, 16) for b in row.split(",") if b)
        font.add(key, " " if code in (0, 32) else chr(code) if 32 < code < 127 else "?")
    if hex_paths is None:
        hex_paths = [p for p in os.environ.get("QUARK_FONT_HEX", "").split(os.pathsep) if p]
    for hex_path in hex_paths:
        for line in open(hex_path):
            name, _, bits = line.strip().partition(":")
            if len(bits) not in (4 * GLYPH_H // 2, 4 * GLYPH_H):
                continue
            key = tuple(int(bits[i:i + 2], 16) for i in range(0, len(bits), 2))
            code = int(name, 16)
            font.add(key, " " if code in (0, 32) or not any(key) else chr(code))
    return font


def read_ppm(path):
    data = open(path, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise ValueError("not a binary PPM: " + path)
    return int(m.group(1)), int(m.group(2)), data[m.end():]


def lookup(glyphs, key):
    char = glyphs.get(key)
    if char is None:
        # More ink than ground: the same glyph in reverse video.
        char = glyphs.get(tuple(b ^ 0xFF for b in key))
    return char


def cell_key(px, w, row, col, across):
    """The shape in a cell `across` pixels wide: one byte to eight pixels,
    row by row."""
    cell = []
    for y in range(GLYPH_H):
        at = ((row * GLYPH_H + y) * w + col * GLYPH_W) * 3
        cell.append([px[at + x * 3:at + x * 3 + 3] for x in range(across)])
    ground = Counter(p for line in cell for p in line).most_common(1)[0][0]
    key = []
    for line in cell:
        for start in range(0, across, 8):
            key.append(sum((p != ground) << (7 - x) for x, p in enumerate(line[start:start + 8])))
    return tuple(key)


# A row of text is sixteen rows of pixels, and most of a screen is the same
# from one look to the next: rows already read are remembered by their pixels.
_ROWS = {}


def screen_lines(path, font):
    """The screen as a list of lines, trailing blanks and blank lines gone."""
    w, h, px = read_ppm(path)
    lines = []
    cols = w // GLYPH_W
    for row in range(h // GLYPH_H):
        raw = px[row * GLYPH_H * w * 3:(row + 1) * GLYPH_H * w * 3]
        known = _ROWS.get(raw)
        if known is not None:
            lines.append(known)
            continue
        out = []
        col = 0
        while col < cols:
            key = cell_key(px, w, row, col, GLYPH_W)
            char = lookup(font.narrow, key)
            if char is None and key[-2:] == (0xFF, 0xFF):
                # The cursor is the bottom two rows of its cell, drawn over
                # whatever is there.
                char = lookup(font.narrow, key[:-2] + (0, 0))
            if char is None and font.wide and col + 1 < cols:
                # Not a character one cell wide. One two cells wide, perhaps.
                char = lookup(font.wide, cell_key(px, w, row, col, 2 * GLYPH_W))
                if char is not None:
                    out.append(char)
                    col += 2
                    continue
            out.append("?" if char is None else char)
            col += 1
        text = "".join(out).rstrip()
        if len(_ROWS) > 2000:
            _ROWS.clear()
        _ROWS[raw] = text
        lines.append(text)
    while lines and not lines[-1]:
        lines.pop()
    return lines


def merge(seen, lines):
    """Add a screen to a transcript of the screens before it.

    The screen is a window on what has been printed, so its top is somewhere
    in what is already written down: find the longest run where the end of
    one is the start of the other, and add what follows. A screen that shares
    nothing with the last — it scrolled a whole page between two looks, or it
    was cleared — is added whole, after a mark. The last line is left off: it
    is still being written.
    """
    body = lines[:-1]
    for k in range(min(len(seen), len(body)), 0, -1):
        if seen[-k:] == body[:k]:
            seen.extend(body[k:])
            return
    if seen and body:
        seen.append("[...]")
    seen.extend(body)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    font = load_font(sys.argv[2]) if len(sys.argv) > 2 else load_font()
    print("\n".join(screen_lines(sys.argv[1], font)))
