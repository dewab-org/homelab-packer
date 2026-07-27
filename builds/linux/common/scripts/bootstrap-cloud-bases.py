#!/usr/bin/env python3
"""Bootstrap all *-cloud base templates from cloud-base-images.json.

Thin wrapper around bootstrap-base-template.py: for each entry in the
manifest it invokes the bootstrap with the pinned image URL, literal sha256,
base VMID, and template name. Proxmox connection settings come from the
usual PROXMOX_* environment variables (see bootstrap-base-template.py).

Usage:
    bootstrap-cloud-bases.py [--only NAME[,NAME...]] [--overwrite] [--refresh-image]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE.parent / "cloud-base-images.json"
BOOTSTRAP = HERE / "bootstrap-base-template.py"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="Comma-separated base template names to bootstrap")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--refresh-image", action="store_true")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    manifest.pop("_comment", None)
    selected = set(args.only.split(",")) if args.only else set(manifest)
    unknown = selected - set(manifest)
    if unknown:
        raise SystemExit(f"Unknown base template(s): {', '.join(sorted(unknown))}")

    failures: list[str] = []
    for name, spec in manifest.items():
        if name not in selected:
            continue
        image_name = spec["image_url"].rsplit("/", 1)[-1]
        cmd = [
            sys.executable,
            str(BOOTSTRAP),
            "--base-vm-id", str(spec["vmid"]),
            "--base-template-name", name,
            "--image-url", spec["image_url"],
            "--checksum", spec["sha256"],
            "--import-filename", image_name,
        ]
        if args.overwrite:
            cmd.append("--overwrite")
        if args.refresh_image:
            cmd.append("--refresh-image")
        print(f"==> {name} (VMID {spec['vmid']}) from {image_name}")
        if subprocess.run(cmd).returncode != 0:
            failures.append(name)

    if failures:
        print(f"FAILED: {', '.join(failures)}", file=sys.stderr)
        return 1
    print("All cloud base templates bootstrapped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
