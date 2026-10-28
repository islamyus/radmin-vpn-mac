#!/usr/bin/env python3
"""Stable local development signer. Does not add a trusted root or touch login keys."""
import argparse
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import re

parser = argparse.ArgumentParser()
parser.add_argument('--identifier', required=True)
parser.add_argument('path', type=Path)
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,200}', args.identifier) or not args.path.exists():
    parser.error('An existing code path and a plain code identifier are required')

ROOT = Path(__file__).resolve().parent.parent
SIGNING = ROOT / 'build/local-signing'
os.umask(0o077)
SIGNING.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(SIGNING, 0o700)
password_path = SIGNING / 'keychain-password'
if not password_path.exists():
    with password_path.open('x') as out:
        out.write(secrets.token_hex(32) + '\n')
password = password_path.read_text().strip()

def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = result.stderr.decode('utf-8', errors='replace').replace(password, '[redacted]')[:600]
        raise SystemExit('{} failed: {}'.format(Path(args[0]).name, detail))
    return result.stdout

key = SIGNING / 'signing.key'
certificate = SIGNING / 'certificate.pem'
der = SIGNING / 'certificate.der'
p12 = SIGNING / 'identity.p12'
keychain = SIGNING / 'signing.keychain-db'
config = SIGNING / 'certificate.cnf'
if not key.exists():
    run('/usr/bin/openssl', 'genrsa', '-aes256', '-passout', 'file:' + str(password_path), '-out', str(key), '3072')
if not certificate.exists():
    with config.open('x') as out:
        out.write('''[req]
prompt = no
distinguished_name = dn
x509_extensions = signing
[dn]
CN = Radmin VPN Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
    run('/usr/bin/openssl', 'req', '-new', '-x509', '-sha256', '-days', '3650', '-key', str(key), '-passin', 'file:' + str(password_path), '-config', str(config), '-out', str(certificate))
if not der.exists():
    run('/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER', '-out', str(der))
if not p12.exists():
    # OpenSSL treats the same file for passin/passout as two successive lines.
    p12_password = SIGNING / 'p12-password'
    if not p12_password.exists():
        with p12_password.open('x') as out: out.write(password + '\n')
    run('/usr/bin/openssl', 'pkcs12', '-export', '-name', 'Radmin VPN Local Development', '-inkey', str(key), '-passin', 'file:' + str(password_path), '-in', str(certificate), '-out', str(p12), '-passout', 'file:' + str(p12_password))
if not keychain.exists():
    original = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user').decode())
    try:
        run('/usr/bin/security', 'create-keychain', '-p', password, str(keychain))
    finally:
        run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original)
    run('/usr/bin/security', 'set-keychain-settings', '-lut', '21600', str(keychain))
    run('/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain))
    run('/usr/bin/security', 'import', str(p12), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign')
    run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain))
else:
    run('/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain))
fingerprint = hashlib.sha1(der.read_bytes()).hexdigest()
requirement = 'designated => identifier "{}" and certificate leaf = H"{}"'.format(args.identifier, fingerprint)
run('/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain), '--timestamp=none', '--identifier', args.identifier, '--requirements', '=' + requirement, str(args.path))
run('/usr/bin/codesign', '--verify', '--strict', str(args.path))
print('Signed with stable local identity:', args.path.name)
