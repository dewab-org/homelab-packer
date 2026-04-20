#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

if __name__ == "__main__":
    _venv_python = Path(__file__).resolve().parent / ".venv" / "bin" / "python3"
    if _venv_python.is_file() and os.access(_venv_python, os.X_OK) and sys.executable != str(_venv_python):
        os.execv(str(_venv_python), [str(_venv_python)] + sys.argv)

import argparse
import re
import signal
import shutil
import subprocess
import tempfile
from typing import TYPE_CHECKING
from urllib.parse import urlparse

if TYPE_CHECKING:
    from proxmoxer import ProxmoxAPI


BUILD_BLOCK_RE = re.compile(r"^\s*build\s*{", re.MULTILINE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build Proxmox templates with Packer",
        usage="%(prog)s [--ask] [--overwrite] [--skip] [--init-only|--validate-only] [all|<build-dir>]",
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--init-only",
        action="store_true",
        help="run packer init only for the selected build target(s)",
    )
    mode.add_argument(
        "--validate-only",
        action="store_true",
        help="run packer init and packer validate for the selected build target(s)",
    )
    parser.add_argument("target", nargs="?", help="build directory or 'all'")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parent


def ensure_venv_bin_on_path() -> None:
    venv_bin = repo_root() / ".venv" / "bin"
    if not venv_bin.is_dir():
        return

    current_path = os.environ.get("PATH", "")
    path_parts = current_path.split(os.pathsep) if current_path else []
    venv_bin_str = str(venv_bin)
    if venv_bin_str not in path_parts:
        os.environ["PATH"] = os.pathsep.join([venv_bin_str, *path_parts]) if path_parts else venv_bin_str


def list_build_dirs() -> list[str]:
    builds_root = repo_root() / "builds"
    build_dirs: list[str] = []

    build_files = sorted(
        builds_root.glob("**/build.pkr.hcl"),
        key=lambda path: tuple(
            int(part) if part.isdigit() else part
            for part in path.parent.relative_to(repo_root()).parts
        ),
    )

    for build_file in build_files:
        build_dir = build_file.parent
        build_vars = build_dir / "variables.auto.pkrvars.hcl"

        # Keep "all" aligned to the buildable templates only. Stub directories
        # do not have per-build vars and may omit a real build block.
        if not build_vars.exists():
            continue
        if not BUILD_BLOCK_RE.search(build_file.read_text()):
            continue

        build_dirs.append(str(build_dir.relative_to(repo_root())))

    return build_dirs


def resolve_targets(target: str | None) -> list[str]:
    if not target:
        return []

    build_dirs = list_build_dirs()
    if target == "all":
        return build_dirs
    if target in build_dirs:
        return [target]
    return []


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


def generate_build_ssh_keypair() -> tuple[str, str, Path]:
    tmpdir = Path(tempfile.mkdtemp(prefix="packer-ssh-key-"))
    key_path = tmpdir / "id_ed25519"
    subprocess.check_call(
        [
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-f",
            str(key_path),
            "-C",
            "packer-build",
        ]
    )
    public_key = key_path.with_suffix(".pub").read_text().strip()
    return str(key_path), public_key, tmpdir


def proxmox_client() -> "ProxmoxAPI | None":
    url = os.environ.get("PROXMOX_URL", "")
    user = os.environ.get("PROXMOX_USERNAME", "")
    password = os.environ.get("PROXMOX_PASSWORD", "")
    if not url or not user or not password:
        return None

    parsed = urlparse(url)
    if not parsed.scheme or not parsed.hostname:
        return None

    from proxmoxer import ProxmoxAPI

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


def build_packer_args(
    build_dir: Path,
    common_vars: Path,
    build_vars: Path,
    ssh_private_key_file: str | None = None,
    ssh_public_key_build: str | None = None,
) -> list[str]:
    packer_args = []
    packer_args.append(f"-var-file={common_vars}")
    if build_vars.exists():
        packer_args.append(f"-var-file={build_vars}")
    if ssh_private_key_file:
        packer_args.append(f"-var=ssh_private_key_file={ssh_private_key_file}")
    if ssh_public_key_build:
        packer_args.append(f"-var=ssh_public_key_build={ssh_public_key_build}")
    packer_args.append(str(build_dir))
    return packer_args


def run_command(command: list[str]) -> int:
    proc = subprocess.Popen(command)
    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.send_signal(signal.SIGINT)
        try:
            return proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            return proc.wait()


def run_packer_init(build_dir: Path) -> int:
    return run_command(["packer", "init", str(build_dir)])


def run_packer_validate(build_dir: Path, common_vars: Path) -> int:
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    ssh_private_key_file, ssh_public_key_build, ssh_key_tmpdir = generate_build_ssh_keypair()
    try:
        packer_args = ["packer", "validate", *build_packer_args(build_dir, common_vars, build_vars, ssh_private_key_file, ssh_public_key_build)]
        return run_command(packer_args)
    finally:
        shutil.rmtree(ssh_key_tmpdir, ignore_errors=True)


def run_packer(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    ssh_private_key_file, ssh_public_key_build, ssh_key_tmpdir = generate_build_ssh_keypair()
    try:
        packer_args = ["packer", "build"]
        if args.ask:
            packer_args.append("-on-error=ask")
        if args.overwrite:
            packer_args.append("-force")
        packer_args.extend(build_packer_args(build_dir, common_vars, build_vars, ssh_private_key_file, ssh_public_key_build))
        return run_command(packer_args)
    finally:
        shutil.rmtree(ssh_key_tmpdir, ignore_errors=True)


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
    ensure_venv_bin_on_path()
    root = repo_root()
    common_vars = root / "variables.auto.pkrvars.hcl"

    if not args.target:
        print("Usage: build.py [--ask] [--overwrite] [--skip] [--init-only|--validate-only] [all|<build-dir>]")
        return 1

    targets = resolve_targets(args.target)
    if not targets:
        print(f"Unknown build target: {args.target}", file=sys.stderr)
        print("Available build targets:", file=sys.stderr)
        for build_dir in list_build_dirs():
            print(f"  - {build_dir}", file=sys.stderr)
        return 1

    for build in targets:
        build_dir = root / build
        if args.init_only:
            status = run_packer_init(build_dir)
        elif args.validate_only:
            status = run_packer_init(build_dir)
            if status == 0:
                status = run_packer_validate(build_dir, common_vars)
        else:
            status = run_build(build_dir, common_vars, args)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
