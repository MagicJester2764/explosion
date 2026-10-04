#!/usr/bin/env python3
"""Echo everything back, over UDP and TCP, on one port of this machine.

    ./echo-server.py [port]            # 7007 if not given

QEMU's user network shows the host's loopback to the guest as 10.0.2.2, and
over IPv6 as fec0::2, so a program on Quark reaches this at 10.0.2.2:<port>
and [fec0::2]:<port>. boot-test.sh starts one if none is listening and leaves
it running — every run there is at once uses the one — which is what lets a
test of the network server check that what it sent came back. Stop it by hand
when there is nothing left to test.

Each family is listened on by itself: one that another echo server has
already, or that this machine has no loopback for, is left to it, and a
server that has neither ends by itself.

TCP connections are echoed until the client closes; datagrams are sent back to
whoever sent them, a moment later.
"""
import socket
import socketserver
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7007


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Server6(Server):
    address_family = socket.AF_INET6


def udp(s):
    while True:
        data, peer = s.recvfrom(65536)
        # Quark's network server keeps no datagram for a reader that has not
        # asked yet, and a program sends before it can wait to receive.
        time.sleep(0.3)
        s.sendto(data, peer)


listening = 0
for family, host, kind in ((socket.AF_INET, "127.0.0.1", Server), (socket.AF_INET6, "::1", Server6)):
    try:
        tcp = kind((host, PORT), Echo)
    except OSError:
        continue
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    listening += 1
    try:
        s = socket.socket(family, socket.SOCK_DGRAM)
        s.bind((host, PORT))
    except OSError:
        continue
    threading.Thread(target=udp, args=(s,), daemon=True).start()

if not listening:
    sys.exit(0)
threading.Event().wait()
