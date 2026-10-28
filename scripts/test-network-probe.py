#!/usr/bin/env python3
"""Loopback protocol fixture: validates the native test, not Radmin throughput."""
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / 'native/target/release/radmin-network-test'
MAGIC = b'RVMAC001'

def exact(stream, size):
    output = bytearray()
    while len(output) < size:
        block = stream.recv(size-len(output))
        if not block:
            raise EOFError()
        output.extend(block)
    return bytes(output)

class Fixture(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        header = exact(self.request, 13)
        assert header[:8] == MAGIC
        size = struct.unpack('>I', header[9:])[0]
        sha = hashlib.sha256()
        while size:
            count = min(size, 65536)
            if header[8:9] == b'U':
                block = exact(self.request, count)
            else:
                block = os.urandom(count)
                # Deliberately split a write to exercise stream reassembly.
                self.request.sendall(block[:3])
                self.request.sendall(block[3:])
            sha.update(block)
            size -= count
        digest = sha.digest()
        if self.server.corrupt:
            digest = bytes(32)
        self.request.sendall(digest[:7])
        self.request.sendall(digest[7:])

class ProbeTests(unittest.TestCase):
    def run_fixture(self, corrupt, drop_first=False):
        with Fixture(('127.0.0.1', 0), Handler) as server:
            server.corrupt = corrupt
            echo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            echo.bind(server.server_address)
            echo.settimeout(.2)
            stop = threading.Event()
            def udp():
                received = 0
                while not stop.is_set():
                    try:
                        data, address = echo.recvfrom(1500)
                        received += 1
                        if drop_first and received == 1:
                            continue
                        echo.sendto(data, address)
                    except socket.timeout:
                        pass
            listener = threading.Thread(target=server.serve_forever, daemon=True)
            udp_listener = threading.Thread(target=udp, daemon=True)
            listener.start(); udp_listener.start()
            output = ROOT / 'build/probe-fixtures' / f'{time.time_ns()}-corrupt-{corrupt}'
            try:
                result = subprocess.run([str(BINARY), '--source', '127.0.0.1', '--peer', '127.0.0.1',
                    '--port', str(server.server_address[1]), '--mib', '1', '--rounds', '1',
                    '--allow-loopback', '--output', str(output), '--label', 'local-fixture'],
                    capture_output=True, text=True, timeout=30)
            finally:
                stop.set(); server.shutdown(); udp_listener.join(); echo.close(); listener.join()
            report = json.loads((output/'report.json').read_text())
            self.assertTrue((output/'initial.json').is_file())
            self.assertTrue((output/'Результат.txt').is_file())
            self.assertTrue(report['local_fixture'])
            self.assertEqual(report['udp_idle']['received'], 9 if drop_first else 10)
            self.assertEqual(report['udp_after']['received'], 10)
            return result, report

    def test_real_socket_transfer_and_split_digest(self):
        result, report = self.run_fixture(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report['all_transfers_sha256_verified'])
        for direction in ('upload', 'download'):
            self.assertEqual(report['rounds'][0][direction]['bytes'], 1048576)
            self.assertTrue(report['rounds'][0][direction]['sha256_verified'])

    def test_corruption_is_reported_as_failure_and_report_survives(self):
        result, report = self.run_fixture(True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(report['all_transfers_sha256_verified'])
        self.assertIn('SHA-256 mismatch', report['rounds'][0]['upload']['error'])
        self.assertIn('SHA-256 mismatch', report['rounds'][0]['download']['error'])

    def test_udp_loss_is_a_warning_even_with_intact_payloads(self):
        result, report = self.run_fixture(False, drop_first=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(report['all_transfers_sha256_verified'])
        self.assertEqual(report['verdict'], 'warning')

if __name__ == '__main__':
    unittest.main()
