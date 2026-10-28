#!/usr/bin/env python3
"""Headless synthetic checks; use only the dedicated project test keychain."""
from pathlib import Path
import hashlib
import json
import subprocess
import time
from build_support import macos_toolchain

root = Path(__file__).resolve().parent.parent
stage = root / 'build/identity-helper-tests' / str(time.time_ns())
stage.mkdir(parents=True)
signing = root / 'build/local-signing'
fingerprint = hashlib.sha1((signing / 'certificate.der').read_bytes()).hexdigest()
requirement = f'identifier "dev.radminvpn.mac.native.engine" and certificate leaf = H"{fingerprint}"'
clang, sdk = macos_toolchain()
helper = stage / 'fixture-helper'
subprocess.run([clang, '-isysroot', sdk, '-Wno-deprecated-declarations',
                '-DENGINE_REQUIREMENT=' + json.dumps(requirement),
                '-DFIXTURE_KEYCHAIN=' + json.dumps(str(signing / 'signing.keychain-db')),
                '-DIDENTITY_SERVICE=' + json.dumps('dev.radminvpn.fixture-only.v2'),
                '-DLEGACY_SERVICE=' + json.dumps('dev.radminvpn.fixture-only.legacy'),
                str(root / 'native/identity-helper.c'), '-framework', 'Security',
                '-framework', 'CoreFoundation', '-o', str(helper)], check=True)
subprocess.run(['python3', str(root / 'scripts/sign-local.py'), '--identifier',
                'dev.radminvpn.mac.identity-helper', str(helper)], check=True)
clients = []
for number in (1, 2):
    client = stage / f'parent-{number}'
    subprocess.run([clang, '-isysroot', sdk, '-O' + str(number),
                    str(root / 'scripts/test-identity-helper-client.c'), '-o', str(client)], check=True)
    subprocess.run(['python3', str(root / 'scripts/sign-local.py'), '--identifier',
                    'dev.radminvpn.mac.native.engine', str(client)], check=True)
    clients.append(client)
account = '/synthetic-only/' + stage.name
def operation(parent, op, expected, matches=0, mode='normal'):
    result = subprocess.run([str(parent), str(helper), op, account, mode],
                            capture_output=True, text=True, timeout=10, check=True)
    assert result.stdout.strip() == f'status={expected} matches_fixture={matches}', result.stdout
    print(f'{op}: status {expected}, fixture comparison {matches}')

unsigned = subprocess.run([str(helper), 'read', account], capture_output=True, timeout=5)
assert unsigned.returncode == 12 and not unsigned.stdout
operation(clients[0], 'read', 10)
operation(clients[0], 'store', 0)
operation(clients[1], 'read', 0, 1)
operation(clients[1], 'store', 11, mode='mismatch')
operation(clients[0], 'read', 0, 1)
assert clients[0].read_bytes() != clients[1].read_bytes()
print('PASS: unsigned caller rejected; two different signed parents; read/store; no replacement. Keychain UI disabled.')
