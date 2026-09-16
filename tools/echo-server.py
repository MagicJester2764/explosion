#!/usr/bin/env python3
"""Echo everything back, over UDP and TCP, on one port of this machine.

    ./echo-server.py [port]            # 7007 if not given

QEMU's user network shows the host's loopback to the guest as 10.0.2.2, so a
program on Quark reaches this at 10.0.2.2:<port>. boot-test.sh starts one for
every run and stops it afterwards, which is what lets a test of the network
server check that what it sent came back.

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


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    while True:
        data, peer = s.recvfrom(65536)
        # Quark's network server keeps no datagram for a reader that has not
        # asked yet, and a program sends before it can wait to receive.
        time.sleep(0.3)
        s.sendto(data, peer)


threading.Thread(target=udp, daemon=True).start()
with Server(("127.0.0.1", PORT), Echo) as server:
    server.serve_forever()
