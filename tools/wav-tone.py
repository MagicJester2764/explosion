#!/usr/bin/env python3
"""Whether a machine played tones: wav-tone.py <wav> <hz> [<hz> ...]

Reads what QEMU's `wav` audio backend has written — the machine's sound
card's output, as the card played it, which `tools/boot-test.sh` with
`AUDIO=1` writes to "$RUN/audio.wav" — and finds the loudest tenth of a
second in it. Each tone named must be there, together holding most of
that tenth's power, with each of them a fair share; and a tone halfway
between, which nobody played, must not be.

Read while the machine is still running: QEMU writes the header's lengths
only when it stops, so what follows the header is taken as it is.

Exits 0 if the tones are there, 1 if not, saying what it heard.
"""
import array
import math
import struct
import sys

path, tones = sys.argv[1], [float(f) for f in sys.argv[2:]]
if not tones:
    sys.exit("usage: wav-tone.py <wav> <hz> [<hz> ...]")
data = open(path, "rb").read()
if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
    sys.exit("wav-tone: not a WAV file")

# The format, and where the samples begin.
at, rate, channels, start = 12, 0, 0, None
while at + 8 <= len(data):
    kind, length = data[at:at + 4], struct.unpack("<I", data[at + 4:at + 8])[0]
    if kind == b"fmt ":
        _, channels, rate = struct.unpack("<HHI", data[at + 8:at + 16])
        bits = struct.unpack("<H", data[at + 22:at + 24])[0]
        if bits != 16:
            sys.exit("wav-tone: only sixteen-bit samples")
    elif kind == b"data":
        start = at + 8
        break
    at += 8 + length + (length & 1)
if start is None or not rate or not channels:
    sys.exit("wav-tone: no samples")

samples = array.array("h")
body = data[start:]
samples.frombytes(body[:len(body) - len(body) % (2 * channels)])
if sys.byteorder != "little":
    samples.byteswap()
# One channel: the first.
mono = samples[0::channels]
window = rate // 10
if len(mono) < window:
    print(f"wav-tone: {len(mono)} frames: nothing was played")
    sys.exit(1)

# The loudest tenth of a second, a twentieth at a time.
best, best_at = -1.0, 0
for i in range(0, len(mono) - window + 1, window // 2):
    energy = sum(x * x for x in mono[i:i + window])
    if energy > best:
        best, best_at = energy, i
part = mono[best_at:best_at + window]
if best <= window * 100.0:
    print(f"wav-tone: {len(mono) / rate:.1f} s of sound, and all of it silence")
    sys.exit(1)


def share(hz):
    """The part of the window's power at `hz` (Goertzel)."""
    w = 2 * math.pi * hz / rate
    c = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in part:
        s1, s2 = x + c * s1 - s2, s1
    power = s1 * s1 + s2 * s2 - c * s1 * s2
    return power / (len(part) * best / 2)


shares = {hz: share(hz) for hz in tones}
lowest = min(tones)
nobody = lowest * 1.25 if len(tones) == 1 else (sorted(tones)[0] + sorted(tones)[1]) / 2
stray = share(nobody)
said = ", ".join(f"{hz:g} Hz {shares[hz]:.2f}" for hz in tones)
print(f"wav-tone: {len(mono) / rate:.1f} s of sound; the loudest tenth at {best_at / rate:.2f} s: {said}; {nobody:g} Hz {stray:.2f}")
fair = 0.5 / len(tones)
ok = sum(shares.values()) > 0.7 and all(v > fair for v in shares.values()) and stray < 0.1
sys.exit(0 if ok else 1)
