#!/usr/bin/env python3
"""Collect dependency copyright/license texts from Cargo's resolved sources."""
import argparse
import json
from pathlib import Path

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument("metadata", type=Path)
cli.add_argument("output", type=Path)
cli.add_argument("--sysroot", required=True, type=Path)
args = cli.parse_args()
metadata = json.loads(args.metadata.read_text())
nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
included, queue = set(), [metadata["resolve"]["root"]]
while queue:
    node = queue.pop()
    if node not in included:
        included.add(node)
        queue.extend(nodes[node]["dependencies"])
sections = ["Rust dependency notices\nGenerated from the locked Cargo dependency graph.\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] not in included or package["source"] is None:
        continue  # Project GPL and OpenRad MIT notices are bundled separately.
    root = Path(package["manifest_path"]).parent
    texts = []
    for path in sorted(root.iterdir()):
        if any(term in path.name.upper() for term in ("LICENSE", "LICENCE", "COPYRIGHT", "NOTICE")):
            if path.is_file():
                texts.append(path)
            elif path.is_dir():
                texts.extend(sorted(p for p in path.rglob("*") if p.is_file()))
    license_file = package.get("license_file")
    if license_file and (root/license_file).is_file():
        texts.append(root/license_file)
    header = f"\n{'='*72}\n{package['name']} {package['version']}\nLicense: {package['license']}\n"
    header += f"Source: {package.get('repository') or package['source']}\n"
    if not texts:
        # Some objc2 crates omit the monorepo's MIT file from the registry tarball.
        fallback = Path(__file__).resolve().parent.parent/"native/licenses"/f"{package['name']}-{package['version']}-MIT.txt"
        if fallback.is_file():
            header += "\n"+fallback.read_text()+"\n"
            sections.append(header)
            continue
    for path in dict.fromkeys(texts):
        if path.stat().st_size > 2*1024*1024:
            raise ValueError("unexpected license text size")
        header += f"\n--- {path.relative_to(root)} ---\n"+path.read_text(errors="strict")+"\n"
    if not texts:
        raise ValueError(f"Missing license text for {package['name']}")
    sections.append(header)
standard = args.sysroot/"share/doc/rust/COPYRIGHT-library.html"
sections.append("\nRust standard library notices\n"+standard.read_text())
with args.output.open("x") as output:
    output.write("\n".join(sections))
