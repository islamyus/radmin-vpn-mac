#!/usr/bin/env python3
"""Cache a signed Keychain component independently of engine/UI rebuilds."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
from build_support import host_architecture, macos_toolchain

root = Path(__file__).resolve().parent.parent
source = root / 'native/identity-helper.c'
certificate = root / 'build/local-signing/certificate.der'
fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
requirement = f'identifier "dev.radminvpn.mac.native.engine" and certificate leaf = H"{fingerprint}"'
architecture = host_architecture()
inputs = source.read_bytes() + requirement.encode() + f'{architecture}-macos14-helper-v1'.encode()
directory = root / 'build/identity-helper' / hashlib.sha256(inputs).hexdigest()
directory.mkdir(parents=True, exist_ok=True)
binary = directory / 'radmin-identity-helper'
manifest = directory / 'manifest.json'
if not binary.exists():
    clang, sdk = macos_toolchain()
    subprocess.run([clang, '-isysroot', sdk, '-arch', architecture,
                    '-mmacosx-version-min=14.0', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-Wno-deprecated-declarations', '-DENGINE_REQUIREMENT=' + json.dumps(requirement),
                    str(source), '-framework', 'Security', '-framework', 'CoreFoundation',
                    '-o', str(binary)], check=True)
    subprocess.run(['python3', str(root / 'scripts/sign-local.py'), '--identifier',
                    'dev.radminvpn.mac.identity-helper', str(binary)], check=True)
    manifest.write_text(json.dumps({'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                                    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}, indent=2)+'\n')
else:
    expected = json.loads(manifest.read_text())['sha256']
    if hashlib.sha256(binary.read_bytes()).hexdigest() != expected:
        raise SystemExit('Cached identity helper changed; refusing automatic replacement')
subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
shutil.copy2(binary, root / 'native/target/release/radmin-identity-helper')
print('Stable identity helper:', binary)
