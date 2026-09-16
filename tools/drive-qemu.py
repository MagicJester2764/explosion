#!/usr/bin/env python3
"""Drive a QEMU guest over QMP from a small script of operations.

Operations, one per line:
    sleep <seconds>      wait
    type <text>          type it, \n understood as return
    key <qcode[+qcode]>  press a named key, or a chord
    move <dx> <dy>       relative pointer motion, sent as a short stream
    click <button>       press and release, e.g. "left"
    shot <path>          screendump
    quit                 stop the guest

The timing lives here rather than in the shell that calls it: a foreground
sleep in a tool call is blocked by the harness.
"""
import json
import socket
import sys
import time

sock_path, script_path = sys.argv[1], sys.argv[2]

for _ in range(200):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(sock_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(0.05)
else:
    sys.exit("no QMP socket")

f = s.makefile("rw")
f.readline()  # greeting


def cmd(name, **args):
    f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            return None
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg


cmd("qmp_capabilities")

SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", ":": "semicolon",
    '"': "apostrophe", "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
    "|": "backslash",
}
PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right", ";": "semicolon",
    "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash",
    "\\": "backslash", "`": "grave_accent",
}


def keys_for(ch):
    if ch.isdigit():
        return [ch]
    if ch.islower():
        return [ch]
    if ch.isupper():
        return ["shift", ch.lower()]
    if ch in SHIFTED:
        return ["shift", SHIFTED[ch]]
    if ch in PLAIN:
        return [PLAIN[ch]]
    return []


def send(ch):
    keys = keys_for(ch)
    if not keys:
        return
    cmd("send-key", keys=[{"type": "qcode", "data": k} for k in keys])
    time.sleep(0.06)


for raw in open(script_path):
    line = raw.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    op, _, arg = line.partition(" ")
    if op == "sleep":
        time.sleep(float(arg))
    elif op == "type":
        for ch in arg.encode().decode("unicode_escape"):
            send(ch)
    elif op == "key":
        cmd("send-key", keys=[{"type": "qcode", "data": k} for k in arg.split("+")])
        time.sleep(0.1)
    elif op == "move":
        # Relative motion, which is what a PS/2 mouse reports. Sent in a few
        # steps so the guest sees a stream of packets rather than one jump.
        dx, dy = (int(v) for v in arg.split())
        for _ in range(8):
            cmd("input-send-event", events=[
                {"type": "rel", "data": {"axis": "x", "value": dx}},
                {"type": "rel", "data": {"axis": "y", "value": dy}}])
            time.sleep(0.02)
    elif op == "click":
        cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": True, "button": arg}}])
        time.sleep(0.08)
        cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": False, "button": arg}}])
        time.sleep(0.08)
    elif op == "shot":
        cmd("screendump", filename=arg)
        print("shot", arg, flush=True)
    elif op == "quit":
        cmd("quit")
print("done", flush=True)
