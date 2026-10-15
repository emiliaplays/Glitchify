"""Finite synthetic-audio WLAN source; no microphone, music files or account data.

Run: python3 watch/lan_test_server.py --bind YOUR_PRIVATE_IPV4
Serves only /glitchify-tone on port 8765, for at most five minutes. Each response
is a paced 20-second PCM stream with a quiet changing tone and silent intervals.
No firewall changes, cloud exposure, file access, uploads, or request logging.
"""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import ipaddress
import math
import socket
import struct
import time

RATE = 24_000
FRAMES = 2_400
BLOCKS = 200
SIZE = FRAMES * BLOCKS * 2
FORMAT = 'pcm_s16le_24000_mono'


def allowed_address(text):
    address = ipaddress.IPv4Address(text)
    networks = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')
    return any(address in ipaddress.IPv4Network(net) for net in networks) and int(address) & 255 not in (0, 255)


def tone_block(block):
    if not 0 <= block < BLOCKS:
        raise ValueError('Invalid block')
    samples = []
    for index in range(FRAMES):
        frame = block * FRAMES + index
        second = frame // RATE
        position = frame % RATE
        fade = min(1.0, position / 1200, (RATE - 1 - position) / 1200)
        # Silence every fifth second makes stale/repeated buffered output audible.
        value = 0 if second % 5 == 4 else int(900 * fade * math.sin(2 * math.pi * (440 + 110 * (second % 4)) * frame / RATE))
        samples.append(value)
    return struct.pack('<' + 'h' * FRAMES, *samples)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        self.request.settimeout(3)
        super().setup()

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.close_connection = True
        if self.path != '/glitchify-tone' or not allowed_address(self.client_address[0]):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(SIZE))
        self.send_header('X-Glitchify-Format', FORMAT)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        started = time.monotonic()
        sent = 0
        print('Synthetic WLAN test started.', flush=True)
        try:
            for block in range(BLOCKS):
                if time.monotonic() >= self.server.expires_at:
                    break
                data = tone_block(block)
                self.wfile.write(data)
                self.wfile.flush()
                sent += len(data)
                time.sleep(max(0, started + (block + 1) / 10 - time.monotonic()))
        except (ConnectionError, TimeoutError, socket.timeout):
            pass
        print(f'Synthetic WLAN test finished: {sent}/{SIZE} bytes.', flush=True)


class QuietHTTPServer(HTTPServer):
    def handle_error(self, request, client_address):
        print('Test connection closed before completion.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', required=True)
    args = parser.parse_args()
    if not allowed_address(args.bind):
        parser.error('Bind to one RFC1918 private IPv4 interface, not all interfaces.')
    with QuietHTTPServer((args.bind, 8765), Handler) as server:
        server.timeout = 1
        server.expires_at = time.monotonic() + 300
        print('WLAN synthetic-audio server ready for five minutes; one request at a time.', flush=True)
        while time.monotonic() < server.expires_at:
            server.handle_request()
    print('WLAN test server stopped.', flush=True)


if __name__ == '__main__':
    main()
