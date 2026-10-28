#!/usr/bin/env python3
"""Measure owned Mac/Windows endpoints through the configured VPN IP interface.

Run Start-RadminNetworkTest.ps1 on Windows first. Payloads are random and
verified with SHA-256. No settings, routes or firewall rules are changed.
"""
import argparse
import hashlib
import ipaddress
import json
import secrets
import socket
import statistics
import struct
import time

MAGIC = b"RVMAC001"


def address(value):
    ip = ipaddress.IPv4Address(value)
    if ip not in ipaddress.IPv4Network("26.0.0.0/8"):
        raise argparse.ArgumentTypeError("assigned Radmin IPv4 required")
    return str(ip)


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        block = stream.recv(min(65536, count-len(data)))
        if not block:
            raise ConnectionError("test server closed before completing the transfer")
        data.extend(block)
    return bytes(data)


def transfer(source, target, port, size, mode):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as stream:
        stream.settimeout(5)
        stream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        stream.bind((source, 0))
        try:
            stream.connect((target, port))
        except OSError as error:
            raise ConnectionError("TCP connect: "+type(error).__name__) from None
        stream.settimeout(30)
        stream.sendall(MAGIC+mode+struct.pack(">I", size))
        digest = hashlib.sha256()
        started = time.perf_counter()
        remaining = size
        while remaining:
            count = min(65536, remaining)
            if mode == b"U":
                block = secrets.token_bytes(count)
                stream.sendall(block)
            else:
                block = read_exact(stream, count)
            digest.update(block)
            remaining -= len(block)
        try:
            remote_digest = read_exact(stream, 32)
        except OSError as error:
            raise ConnectionError("TCP checksum reply: "+type(error).__name__) from None
        elapsed = time.perf_counter()-started
        if not secrets.compare_digest(remote_digest, digest.digest()):
            raise ValueError("payload SHA-256 mismatch")
        return dict(bytes=size, seconds=round(elapsed, 3),
                    mbps=round(size*8/elapsed/1_000_000, 2), sha256_verified=True)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("target", type=address)
    cli.add_argument("--source", required=True, type=address)
    cli.add_argument("--port", type=int, default=48671)
    cli.add_argument("--mib", type=int, default=16, choices=range(1,65))
    args = cli.parse_args()
    if not 1 <= args.port <= 65535:
        cli.error("invalid port")
    rtts, errors = [], []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
        stream.bind((args.source,0))
        stream.connect((args.target,args.port))
        stream.settimeout(1.5)
        for sequence in range(10):
            message = MAGIC+struct.pack(">I",sequence)+secrets.token_bytes(1188)
            started=time.perf_counter()
            try:
                stream.send(message)
            except OSError as error:
                errors.append(type(error).__name__)
                continue
            until=started+1.5
            while time.perf_counter()<until:
                try:
                    response=stream.recv(1400)
                except OSError as error:
                    errors.append(type(error).__name__)
                    break
                if response==message:
                    rtts.append((time.perf_counter()-started)*1000)
                    break
            time.sleep(0.1)
    udp=dict(sent=10, received=len(rtts), loss_percent=(10-len(rtts))*10,
             median_ms=round(statistics.median(rtts),2) if rtts else None,
             max_ms=round(max(rtts),2) if rtts else None, errors=sorted(set(errors)))
    print(json.dumps(dict(udp=udp)),flush=True)
    size=args.mib*1024*1024
    successful = len(rtts)==10
    for name, mode in (("upload",b"U"),("download",b"D")):
        try:
            result=transfer(args.source,args.target,args.port,size,mode)
        except (OSError,ValueError) as error:
            result=dict(error=type(error).__name__, detail=str(error))
            successful=False
        print(json.dumps({name:result}),flush=True)
    if not successful:
        raise SystemExit(1)


if __name__=="__main__":
    main()
