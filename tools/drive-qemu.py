#!/usr/bin/env python3
"""Drive a QEMU guest over QMP from a small script of operations.

Operations, one per line:
    sleep <seconds>      wait
    type <text>          type it, \n understood as return
    key <qcode[+qcode]>  press a named key, or a chord
    move <dx> <dy> [n]   relative pointer motion, n steps of it (8 by default)
    click <button>       press and release, e.g. "left"
    press <button>       hold it down; `release` lets go, and between the two
                         a `move` is a drag
    release <button>     let go
    wheel <up|down> <n>  n detents of the scroll wheel
    shot <path>          screendump
    expect <seconds> <regex>
                         wait until the last line on the text console matches:
                         a prompt, usually, which is how a script knows the
                         command before it has finished. Gives up after that
                         many seconds, says so, and the run fails.
    text <path>          the text console's screen, as text
    transcript <path>    everything the console has shown while this was
                         looking — at each `expect`, `text` and `transcript` —
                         joined where one screen overlaps the next
    saw <regex>          some line the console has shown matches. What a
                         command printed is the test of it; one that printed
                         something else fails the run and says what was looked
                         for.
    off <seconds>        wait for the machine to turn itself off. Nothing
                         after this runs: there is nothing left to type at.
    hmp <command>        a monitor command, its output printed: `hmp info
                         registers` says where a guest that stopped
                         answering is spending its time
    quit                 stop the guest

The timing lives here rather than in the shell that calls it: a foreground
sleep in a tool call is blocked by the harness.

Exits 1 if an `expect` gave up, a `saw` saw nothing, or the machine was
still on when `off` stopped waiting.
"""
import json
import os
import re
import socket
import sys
import time

import screentext

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

# Reading the screen: a screendump beside the socket, and the font the console
# draws with. The font is loaded the first time something asks, so a script
# that only types and takes pictures needs no userland checkout.
GLYPHS = None
SEEN = []
SCRATCH = os.path.join(os.path.dirname(os.path.abspath(sock_path)), "screen.ppm")
FAILED = False


def screen():
    """What the text console shows now; also written into the transcript."""
    global GLYPHS
    if GLYPHS is None:
        GLYPHS = screentext.load_font()
    lines = []
    # A dump taken while the guest changes mode can be short. Look again.
    for _ in range(5):
        cmd("screendump", filename=SCRATCH)
        try:
            lines = screentext.screen_lines(SCRATCH, GLYPHS)
            break
        except (OSError, ValueError, IndexError):
            time.sleep(0.2)
    if lines:
        screentext.merge(SEEN, lines)
    return lines

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
        # The step count is there for aiming: a target a few pixels wide is
        # not reachable in whole multiples of eight.
        parts = arg.split()
        dx, dy = int(parts[0]), int(parts[1])
        steps = int(parts[2]) if len(parts) > 2 else 8
        for _ in range(steps):
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
    elif op == "press" or op == "release":
        # Held down across other operations, which is what a drag is: a press,
        # a stream of motion, and a release somewhere else. `click` cannot
        # express that because it does both ends at once.
        cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": op == "press", "button": arg}}])
        time.sleep(0.08)
    elif op == "wheel":
        # A wheel is a button in QEMU's input model, not an axis: one detent is
        # a press and a release of "wheel-up" or "wheel-down", which the PS/2
        # mouse emulation turns into the Z byte of an IMPS/2 packet.
        where, _, count = arg.partition(" ")
        for _ in range(int(count or 1)):
            cmd("input-send-event", events=[
                {"type": "btn", "data": {"down": True, "button": "wheel-" + where}}])
            cmd("input-send-event", events=[
                {"type": "btn", "data": {"down": False, "button": "wheel-" + where}}])
            time.sleep(0.08)
    elif op == "shot":
        cmd("screendump", filename=arg)
        print("shot", arg, flush=True)
    elif op == "expect":
        seconds, _, pattern = arg.partition(" ")
        deadline = time.time() + float(seconds)
        while True:
            lines = screen()
            if lines and re.search(pattern, lines[-1]):
                break
            if time.time() >= deadline:
                print("expect: gave up after", seconds, "s waiting for", pattern, flush=True)
                print("        the last line was:", repr(lines[-1] if lines else ""), flush=True)
                FAILED = True
                break
            time.sleep(0.2)
    elif op == "saw":
        lines = SEEN + screen()
        if not any(re.search(arg, line) for line in lines):
            print("saw: nothing the console showed matches", arg, flush=True)
            FAILED = True
    elif op == "off":
        deadline = time.time() + float(arg)
        gone = False
        while time.time() < deadline:
            # A machine that has turned itself off has closed this socket.
            try:
                if cmd("query-status") is None:
                    gone = True
                    break
            except (BrokenPipeError, ConnectionResetError, OSError):
                gone = True
                break
            time.sleep(0.5)
        if not gone:
            print("off: still running after", arg, "s", flush=True)
            FAILED = True
        else:
            print("off", flush=True)
        break
    elif op == "text":
        with open(arg, "w") as out:
            out.write("\n".join(screen()) + "\n")
        print("text", arg, flush=True)
    elif op == "transcript":
        last = screen()
        with open(arg, "w") as out:
            out.write("\n".join(SEEN + last[-1:]) + "\n")
        print("transcript", arg, flush=True)
    elif op == "hmp":
        reply = cmd("human-monitor-command", **{"command-line": arg})
        print("hmp", arg, flush=True)
        print((reply or {}).get("return", reply), flush=True)
    elif op == "quit":
        cmd("quit")
print("done", flush=True)
# The socket may be the machine's that has just turned itself off.
try:
    f.close()
except OSError:
    pass
sys.exit(1 if FAILED else 0)
