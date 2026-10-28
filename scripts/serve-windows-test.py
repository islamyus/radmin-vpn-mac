#!/usr/bin/env python3
"""Serve only our public test script to one owned Radmin peer, for ten minutes."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import time

cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument("--bind",required=True)
cli.add_argument("--peer",required=True)
args=cli.parse_args()
payload=(Path(__file__).resolve().parent.parent/"tools/windows/Start-RadminNetworkTest.ps1").read_bytes()
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.client_address[0]!=args.peer or self.path!="/Start-RadminNetworkTest.ps1":
            self.send_error(403)
            return
        self.send_response(200)
        self.send_header("Content-Type","text/plain; charset=utf-8")
        self.send_header("Content-Length",str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        print("Test script delivered to owned Windows peer",flush=True)
    def log_message(self,*args): pass
server=HTTPServer((args.bind,48672),Handler)
server.timeout=1
print("Test-script server ready; SHA256="+hashlib.sha256(payload).hexdigest(),flush=True)
until=time.monotonic()+600
try:
    while time.monotonic()<until: server.handle_request()
finally:
    server.server_close()
