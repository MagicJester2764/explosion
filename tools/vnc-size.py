#!/usr/bin/env python3
"""Ask a machine's display to be another size, as a VNC viewer whose window
was made another size asks, and wait for the machine to show that size.

    vnc-size.py <vnc-socket> <width> <height> [seconds]

QEMU passes the size on to the display device, and a virtio GPU says to the
guest that its display has changed (its display event). A guest whose
driver follows shows a picture of the new size, and the VNC server says so
to its viewers: that is what this waits for. The machine is started with
`-vnc unix:<vnc-socket>`, which `tools/boot-test.sh` does for `VIRTIO=1`.

Exits 0 once the display is the size asked for, and 1 if it is not after
that many seconds — thirty unless said.
"""
import socket
import struct
import sys
import time

path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
patience = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0

s = socket.socket(socket.AF_UNIX)
s.connect(path)
s.settimeout(patience)


def read(n):
    data = b""
    while len(data) < n:
        part = s.recv(n - len(data))
        if not part:
            sys.exit("vnc-size: the server closed the connection")
        data += part
    return data


# RFB 3.8 (RFC 6143), with no security; shared, so a viewer already
# looking is not put off.
read(12)
s.sendall(b"RFB 003.008\n")
types = read(read(1)[0])
if 1 not in types:
    sys.exit("vnc-size: the server wants a password")
s.sendall(bytes([1]))
if struct.unpack(">I", read(4))[0] != 0:
    sys.exit("vnc-size: the server would not have this viewer")
s.sendall(bytes([1]))
was_w, was_h = struct.unpack(">HH", read(4))
bits = read(16)[0]
read(struct.unpack(">I", read(4))[0])
print(f"vnc-size: the display is {was_w}x{was_h}; asking for {width}x{height}", flush=True)

# What this understands: pixels as they are (never asked for), and both
# ways a server says the display is another size. Then the size, as one
# screen at the corner.
encodings = [0, -308, -223]
s.sendall(struct.pack(">BBH", 2, 0, len(encodings)) + b"".join(struct.pack(">i", e) for e in encodings))
s.sendall(struct.pack(">BBHHBB", 251, 0, width, height, 1, 0) + struct.pack(">IHHHHI", 0, 0, 0, width, height, 0))

deadline = time.time() + patience
while True:
    left = deadline - time.time()
    if left <= 0:
        break
    s.settimeout(left)
    try:
        kind = read(1)[0]
    except (socket.timeout, TimeoutError):
        break
    if kind == 0:
        _, rects = struct.unpack(">BH", read(3))
        for _ in range(rects):
            x, y, w, h, encoding = struct.unpack(">HHHHi", read(12))
            if encoding == -308:
                read(16 * read(4)[0])
                # `x` is why: 0 the display itself changed, 1 this viewer's
                # asking, answered with `y` — 4 is "passed on", and the size
                # is still the old one.
                if x == 0 and (w, h) == (width, height):
                    print(f"vnc-size: the display is {w}x{h}", flush=True)
                    sys.exit(0)
                if x == 1 and y not in (0, 4):
                    sys.exit(f"vnc-size: the server refused the size ({y})")
            elif encoding == -223:
                if (w, h) == (width, height):
                    print(f"vnc-size: the display is {w}x{h}", flush=True)
                    sys.exit(0)
            elif encoding == 0:
                read(w * h * bits // 8)
            else:
                sys.exit(f"vnc-size: an encoding not asked for ({encoding})")
    elif kind == 1:
        _, _, n = struct.unpack(">BHH", read(5))
        read(6 * n)
    elif kind == 2:
        pass
    elif kind == 3:
        read(3)
        read(struct.unpack(">I", read(4))[0])
    else:
        sys.exit(f"vnc-size: a message not understood ({kind})")
print(f"vnc-size: the display was not {width}x{height} after {patience:g} s", flush=True)
sys.exit(1)
