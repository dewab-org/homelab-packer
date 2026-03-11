#!/usr/bin/env python3
import argparse
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

from proxmoxer import ProxmoxAPI


BUILDS = [
    "builds/linux/rhel/8",
    "builds/linux/rhel/9",
    "builds/linux/rhel/10",
    "builds/linux/rocky/8",
    "builds/linux/rocky/9",
    "builds/linux/rocky/10",
    "builds/linux/ubuntu/24.04",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build Proxmox templates with Packer",
        usage="%(prog)s [--ask] [--overwrite] [--skip] [all|<build-dir>]",
    )
    parser.add_argument("--ask", action="store_true", help="ask on Packer errors")
    exclusive = parser.add_mutually_exclusive_group()
    exclusive.add_argument(
        "--overwrite", action="store_true", help="overwrite existing template/VMID"
    )
    exclusive.add_argument(
        "--skip",
        action="store_true",
        help="skip builds if template or VMID already exists in Proxmox",
    )
    parser.add_argument("target", nargs="?", help="build directory or 'all'")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parent


def parse_template_name(build_file: Path) -> str:
    if not build_file.exists():
        return ""
    match = re.search(r'template_name\s*=\s*"([^"]+)"', build_file.read_text())
    return match.group(1) if match else ""


def parse_vm_id(build_vars: Path) -> str:
    if not build_vars.exists():
        return ""
    match = re.search(r"vm_id\s*=\s*([0-9]+)", build_vars.read_text())
    return match.group(1) if match else ""




def proxmox_client() -> ProxmoxAPI | None:
    url = os.environ.get("PROXMOX_URL", "")
    user = os.environ.get("PROXMOX_USERNAME", "")
    password = os.environ.get("PROXMOX_PASSWORD", "")
    if not url or not user or not password:
        return None

    parsed = urlparse(url)
    if not parsed.scheme or not parsed.hostname:
        return None

    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return ProxmoxAPI(
        parsed.hostname,
        user=user,
        password=password,
        verify_ssl=False,
        port=port,
    )


def template_exists(build_dir: Path, build_vars: Path) -> bool | None:
    template_name = parse_template_name(build_dir / "build.pkr.hcl")
    vm_id = parse_vm_id(build_vars)

    proxmox = proxmox_client()
    if proxmox is None:
        return None

    try:
        resources = proxmox.cluster.resources.get(type="vm")
    except Exception:
        return None

    for entry in resources:
        if vm_id and str(entry.get("vmid")) == vm_id:
            return True
        if template_name and entry.get("name") == template_name:
            return True
    return False


def run_packer(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    packer_args = ["packer", "build"]
    if args.ask:
        packer_args.append("-on-error=ask")
    if args.overwrite:
        packer_args.append("-force")
    packer_args.append(f"-var-file={common_vars}")
    if build_vars.exists():
        packer_args.append(f"-var-file={build_vars}")
    packer_args.append(str(build_dir))
    proc = subprocess.Popen(packer_args)
    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.send_signal(signal.SIGINT)
        try:
            return proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            return proc.wait()


def run_build(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    if not build_dir.is_dir():
        print(f"Unknown build directory: {build_dir}", file=sys.stderr)
        return 1
    if not common_vars.exists():
        print(f"Missing common vars: {common_vars}", file=sys.stderr)
        return 1

    if args.skip:
        exists = template_exists(build_dir, build_dir / "variables.auto.pkrvars.hcl")
        if exists is True:
            rel = build_dir.relative_to(repo_root())
            print(f"Skipping {rel} (template already exists)")
            return 0
        if exists is None:
            rel = build_dir.relative_to(repo_root())
            print(
                f"Skip requested but unable to query Proxmox; proceeding with {rel}",
                file=sys.stderr,
            )

    return run_packer(build_dir, common_vars, args)


def main() -> int:
    args = parse_args()
    root = repo_root()
    common_vars = root / "variables.auto.pkrvars.hcl"

    if not args.target:
        print("Usage: build.py [--ask] [--overwrite] [--skip] [all|<build-dir>]")
        return 1

    if args.target == "all":
        for build in BUILDS:
            status = run_build(root / build, common_vars, args)
            if status != 0:
                return status
        return 0

    return run_build(root / args.target, common_vars, args)


if __name__ == "__main__":
    raise SystemExit(main())
