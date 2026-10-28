#!/usr/bin/env python3
"""Check a pinned OpenRad checkout offline or authenticate its bootstrap session.

Research only: no device registration, network joins, routes, or packet capture.
The live mode prints record lengths and proof success, never key material.
Requires Python 3.10+ and an explicit local checkout of the MIT project.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

REVISION = "47eb54f6b051aadc37260d405681b2111b50b7cc"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    root = args.checkout.resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != REVISION:
        raise ValueError("OpenRad revision differs from the reviewed source")
    if subprocess.check_output(["git", "-C", str(root), "diff", "HEAD", "--",
                                "clients/python/radproto.py", "clients/python/radvpn.py"]):
        raise ValueError("OpenRad protocol source has local changes")
    sys.path.insert(0, str(root / "clients/python"))
    import radproto as p

    fixture = json.loads((root / "tests/fixtures/reference.json").read_text())
    sh = fixture["sh"]
    messages = [bytes.fromhex(value) for value in sh["messages"]]
    client = p.SHClient(sh["rid"], sh["password"].encode(), private=sh["private"])
    assert client.start() == messages[0]
    assert client.receive_f10(messages[1]) == messages[2]
    assert client.receive_f12(messages[3]) == messages[4]
    assert client.receive_f14(messages[5]).hex() == sh["key"]
    enc, dec = p.PureCC(bytes(range(32))), p.PureCC(bytes(range(32)))
    for entry in fixture["channel"]:
        plain, cipher = bytes.fromhex(entry["pt"]), bytes.fromhex(entry["ct"])
        assert enc.enc(plain) == cipher
        assert dec.dec(cipher) == plain
    enc.set_key(bytes(range(32, 64)))
    dec.set_key(bytes(range(32, 64)))
    entry = fixture["rekey"]
    assert enc.enc(bytes.fromhex(entry["pt"])).hex() == entry["ct"]
    assert dec.dec(bytes.fromhex(entry["ct"])).hex() == entry["pt"]
    print(json.dumps({"revision": revision, "offline_crypto_vectors": "passed"}), flush=True)
    if not args.live:
        return

    from radvpn import Framed
    _, crypto = p.bootstrap_session(p.SERVER_MODULUS)
    sent, received = [], []
    stream = Framed.connect(p.DEFAULT_HOST, p.DEFAULT_PORT)
    until = time.monotonic() + 35
    def send(body):
        stream.send(body, until)
        sent.append(len(body))
    def receive(maximum):
        body = stream.receive(maximum, until)
        received.append(len(body))
        return body
    try:
        send(b"\x03\0\0\0")
        send(crypto.f6)
        reply = crypto.accept_echo(receive(4))
        for handler in (crypto.receive_f10, crypto.receive_f12, crypto.receive_f14):
            send(reply)
            reply = handler(receive(65536))
        print(json.dumps({"bootstrap_server_proof": "verified",
                          "sent_body_lengths": sent, "received_body_lengths": received,
                          "registered_device": False, "joined_network": False}))
    finally:
        stream.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, AssertionError, subprocess.CalledProcessError) as error:
        # Exception text from protocol implementations may include private data.
        print(json.dumps({"ok": False, "error_type": type(error).__name__}), file=sys.stderr)
        raise SystemExit(1)
