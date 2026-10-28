#!/usr/bin/env python3
"""Check tracked publication content without printing possible secret values."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
excluded = ('build/', 'dist/', '.build/', 'hub/', 'experiments/',
            'vendor/radmin-vpn-linux/', '.runtime/', 'docs/capture-')
local_documents = {'docs/local-worklog.md', 'docs/native-protocol-research.md',
                   'docs/protocol-inventory.json', 'docs/macos-port-validation.md',
                   'docs/openrad-research.md', 'docs/performance-031.md',
                   'docs/privileged-helper.md', 'docs/ui-follow-ups.md', 'docs/windows-capture.md'}
private_suffixes = ('.key', '.p12', '.pfx', '.keychain-db', '.pcap', '.pcapng', '.exe', '.dll', '.sys', '.dmg', '.zip')
patterns = [
    ('private key', re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----')),
    ('GitHub credential', re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b')),
    ('GitHub fine-grained credential', re.compile(r'\bgithub_pat_[A-Za-z0-9_]{30,}\b')),
    ('AWS access key', re.compile(r'\bAKIA[A-Z0-9]{16}\b')),
    ('personal macOS home path', re.compile('/' + 'Users/' + r'[^/\s"\']+/')),
]
errors = []
checked = 0
for name in filter(None, paths):
    path = root / name
    if (name in ('AGENTS.md', '.gitmodules') or name in local_documents or
            (path.name.startswith('.env') and path.name != '.env.example') or name.startswith(excluded) or
            '/target/' in name or name.lower().endswith(private_suffixes)):
        errors.append((name, 'excluded/private file'))
        continue
    if not path.is_file():
        errors.append((name, 'missing file or unexpected submodule'))
        continue
    checked += 1
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue  # Upstream image assets are allowed; credentials are not.
    for label, pattern in patterns:
        if pattern.search(text):
            errors.append((name, label))
if errors:
    for name, reason in errors:
        print(f'{name}: {reason}')
    raise SystemExit(f'Publication check failed: {len(errors)} finding(s)')
print(f'Publication check passed: {checked} tracked files; no excluded paths or high-confidence credentials')
