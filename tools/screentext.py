#!/usr/bin/env python3
"""Read a screenshot of the text console back as text.

    tools/screentext.py <shot.ppm> [font.rs]

The console draws an 8x16 bitmap font on a grid, so a screendump of it *is*
its text, exactly: each cell is matched against the font it was drawn with
(`quark-rt/src/font.rs` in the userland, or `QUARK_FONT`). A cell is decided
by which of its pixels differ from its most common colour, so neither the
colour a program printed in nor a background behind it matters. A cell that
matches nothing — part of a window, a picture — is `?`.

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


def load_font(path=FONT):
    """Glyph bitmaps to the character each is, from the Rust table."""
    rows = re.findall(r"\[((?:0x[0-9A-Fa-f]{2},?){16})\]", open(path).read())
    glyphs = {}
    for code, row in enumerate(rows[:256]):
        key = tuple(int(b, 16) for b in row.split(",") if b)
        # The first code to claim a shape keeps it, so blank is a space.
        glyphs.setdefault(key, code)
    return glyphs


def read_ppm(path):
    data = open(path, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise ValueError("not a binary PPM: " + path)
    return int(m.group(1)), int(m.group(2)), data[m.end():]


def lookup(glyphs, key):
    code = glyphs.get(key)
    if code is None:
        # More ink than ground: the same glyph in reverse video.
        code = glyphs.get(tuple(b ^ 0xFF for b in key))
    return code


# A row of text is sixteen rows of pixels, and most of a screen is the same
# from one look to the next: rows already read are remembered by their pixels.
_ROWS = {}


def screen_lines(path, glyphs):
    """The screen as a list of lines, trailing blanks and blank lines gone."""
    w, h, px = read_ppm(path)
    lines = []
    for row in range(h // GLYPH_H):
        raw = px[row * GLYPH_H * w * 3:(row + 1) * GLYPH_H * w * 3]
        known = _ROWS.get(raw)
        if known is not None:
            lines.append(known)
            continue
        out = []
        for col in range(w // GLYPH_W):
            cell = []
            for y in range(GLYPH_H):
                at = ((row * GLYPH_H + y) * w + col * GLYPH_W) * 3
                cell.append([px[at + x * 3:at + x * 3 + 3] for x in range(GLYPH_W)])
            ground = Counter(p for line in cell for p in line).most_common(1)[0][0]
            key = tuple(sum((p != ground) << (7 - x) for x, p in enumerate(line)) for line in cell)
            code = lookup(glyphs, key)
            if code is None and key[-2:] == (0xFF, 0xFF):
                # The cursor is the bottom two rows of its cell, drawn over
                # whatever is there.
                code = lookup(glyphs, key[:-2] + (0, 0))
            if code in (0, 32):
                out.append(" ")
            elif code is not None and 32 < code < 127:
                out.append(chr(code))
            else:
                out.append("?")
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
