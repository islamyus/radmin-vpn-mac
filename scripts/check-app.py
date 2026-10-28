#!/usr/bin/env python3
"""Audit a packaged app without launching it or opening a real profile."""
from pathlib import Path
import re
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: check-app.py PATH.app')
app = Path(sys.argv[1])
if not app.is_dir() or app.suffix != '.app':
    raise SystemExit('An existing application bundle is required')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
private = ('.key', '.p12', '.pfx', '.keychain-db', '.pcap', '.pcapng', '.exe', '.dll', '.sys')
home = re.compile(b'/' + b'Users/' + rb'[^/\s\x00]+/')
errors = []
for path in app.rglob('*'):
    if path.is_symlink():
        errors.append((str(path.relative_to(app)), 'unexpected symlink'))
    elif path.is_file():
        if path.name.endswith(private):
            errors.append((str(path.relative_to(app)), 'private/proprietary artifact'))
        if home.search(path.read_bytes()):
            errors.append((str(path.relative_to(app)), 'personal build path'))
if errors:
    for name, reason in errors:
        print(f'{name}: {reason}')
    raise SystemExit('Application privacy check failed')
print('Application audit passed: valid signature, no private artifacts or personal build paths')
