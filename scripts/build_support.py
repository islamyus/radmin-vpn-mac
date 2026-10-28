"""Select an installed macOS SDK without pinning an Xcode/SDK release."""
import os
import platform
from pathlib import Path
import subprocess


def macos_toolchain():
    environment = dict(os.environ)
    full_xcode = Path('/Applications/Xcode.app/Contents/Developer')
    if 'DEVELOPER_DIR' not in environment and full_xcode.is_dir():
        environment['DEVELOPER_DIR'] = str(full_xcode)
    def locate(*arguments):
        return subprocess.check_output(['xcrun', '--sdk', 'macosx', *arguments],
                                       env=environment, text=True).strip()
    return locate('--find', 'clang'), locate('--show-sdk-path')


def host_architecture():
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise SystemExit('Build on an Apple Silicon or Intel Mac')
    return architecture
