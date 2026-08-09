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
import time
from typing import TYPE_CHECKING
from urllib.parse import urlparse

if TYPE_CHECKING:
    from proxmoxer import ProxmoxAPI


BUILD_BLOCK_RE = re.compile(r"^\s*build\s*{", re.MULTILINE)

# Pause between whole-build retries: long enough for a transient RHN/Satellite
# or Proxmox API blip to clear, short enough not to stall an overnight run.
RETRY_DELAY_SECONDS = 30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build Proxmox templates with Packer",
        usage="%(prog)s [--ask] [--overwrite] [--skip] [--init-only|--validate-only] [all|<build-dir>]",
    )
    parser.add_argument("--ask", action="store_true", help="ask on Packer errors")
    parser.add_argument(
        "--retries",
        type=int,
        default=2,
        metavar="N",
        help="retry a failed packer build up to N times (default 2; 0 disables). "
        "Retries also fire when packer exits 0 but the template is not found in "
        "Proxmox. Ignored with --ask/--init-only/--validate-only.",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="skip the post-build check that the template exists in Proxmox",
    )
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
            (0, int(part), "") if part.isdigit() else (1, 0, part)
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


def is_linux(build_dir: str) -> bool:
    return build_dir.startswith("builds/linux/")


def is_cloud(build_dir: str) -> bool:
    return build_dir.endswith("-cloud")


def resolve_targets(target: str | None) -> list[str]:
    """Map a target keyword or path to concrete build directories.

    Keywords:
      all       cloud-image builds only  <- the default, see below
      cloud     same as "all", spelled explicitly
      iso       ISO/kickstart builds only (opt-in)
      all-linux every Linux build, cloud + ISO (the old "all")

    "all" deliberately means *cloud only*. The cloud builds clone a vendor
    qcow2 and are minutes each; the ISO builds drive an installer through a
    boot command and are far slower and more fragile — GRUB keystroke timing
    has broken them more than once. Both flavours install the same packages
    and customisations (builds/linux/ansible/), so the ISO path earns its
    keep only when a vendor cloud image will not do: a from-scratch
    partition layout, a FIPS/STIG install-time option, or an OS with no
    published cloud image.

    Windows is excluded from every keyword: those builds are in-progress
    stubs that cannot complete unattended. Build them explicitly with
    ./build.py builds/windows/<name>.
    """
    if not target:
        return []

    build_dirs = list_build_dirs()
    linux = [d for d in build_dirs if is_linux(d)]

    if target in ("all", "cloud"):
        return [d for d in linux if is_cloud(d)]
    if target == "iso":
        return [d for d in linux if not is_cloud(d)]
    if target == "all-linux":
        return linux
    if target in build_dirs:
        return [target]
    return []


def parse_template_name(build_file: Path) -> str:
    if not build_file.exists():
        return ""
    match = re.search(r'template_name\s*=\s*"([^"]+)"', build_file.read_text())
    if match:
        return match.group(1)
    match = re.search(
        r'variable\s+"template_name"\s*{[^}]*default\s*=\s*"([^"]+)"',
        build_file.read_text(),
        re.DOTALL,
    )
    return match.group(1) if match else ""


def parse_vm_id(build_vars: Path) -> str:
    if not build_vars.exists():
        return ""
    # Anchor to line start: the cloud pkrvars also carry `clone_vm_id = <base>`
    # (the clone SOURCE), and an unanchored `vm_id\s*=` matches *that* first,
    # so template_exists()/verify_template_built() would check the base VMID
    # (which always exists) instead of the output template. Match only a line
    # whose key is exactly `vm_id`.
    match = re.search(r"^\s*vm_id\s*=\s*([0-9]+)", build_vars.read_text(), re.MULTILINE)
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


def verify_template_built(build_dir: Path, build_vars: Path) -> bool | None:
    """Confirm the build actually produced a Proxmox *template*.

    packer exiting 0 is not proof: a botched finalize step can leave exit 0
    with no template, or a plain VM that never got converted. Match on VMID
    (preferred) or name and require the template flag to be set.

    Returns True/False, or None when Proxmox cannot be queried (no creds) so
    the caller can warn rather than silently trust the exit code.
    """
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
        matches_id = bool(vm_id) and str(entry.get("vmid")) == vm_id
        matches_name = bool(template_name) and entry.get("name") == template_name
        if (matches_id or matches_name) and int(entry.get("template", 0) or 0) == 1:
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


def run_packer(
    build_dir: Path,
    common_vars: Path,
    args: argparse.Namespace,
    force_overwrite: bool = False,
) -> int:
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    ssh_private_key_file, ssh_public_key_build, ssh_key_tmpdir = generate_build_ssh_keypair()
    try:
        packer_args = ["packer", "build"]
        if args.ask:
            packer_args.append("-on-error=ask")
        # Retries must overwrite whatever a failed attempt left behind (a
        # half-built VM or an already-created template on the target VMID),
        # otherwise the retry fails on a name/VMID clash instead of the
        # original transient error.
        if args.overwrite or force_overwrite:
            packer_args.append("-force")
        packer_args.extend(build_packer_args(build_dir, common_vars, build_vars, ssh_private_key_file, ssh_public_key_build))
        return run_command(packer_args)
    finally:
        shutil.rmtree(ssh_key_tmpdir, ignore_errors=True)


def run_build(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    print(f"===== BUILDING {build_dir} =====", flush=True)
    if not build_dir.is_dir():
        print(f"Unknown build directory: {build_dir}", file=sys.stderr)
        return 1
    if not common_vars.exists():
        print(f"Missing common vars: {common_vars}", file=sys.stderr)
        return 1

    build_vars = build_dir / "variables.auto.pkrvars.hcl"

    if args.skip:
        exists = template_exists(build_dir, build_vars)
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

    # --ask hands control to packer's interactive on-error prompt, so an
    # unattended retry loop would fight it; run exactly once in that mode.
    attempts = 1 if args.ask else 1 + max(0, args.retries)
    rel = build_dir.relative_to(repo_root())

    for attempt in range(1, attempts + 1):
        if attempt > 1:
            print(
                f"===== RETRY {attempt - 1}/{attempts - 1} for {rel} "
                f"(waited {RETRY_DELAY_SECONDS}s) =====",
                flush=True,
            )
        status = run_packer(
            build_dir, common_vars, args, force_overwrite=(attempt > 1)
        )

        if status != 0:
            print(
                f"packer build exited {status} for {rel} "
                f"(attempt {attempt}/{attempts})",
                file=sys.stderr,
            )
            if attempt < attempts:
                time.sleep(RETRY_DELAY_SECONDS)
            continue

        # Exit 0 is a claim, not proof: confirm the template really exists.
        if args.no_verify:
            return 0
        verified = verify_template_built(build_dir, build_vars)
        if verified is True:
            print(f"verified: template for {rel} is present in Proxmox")
            return 0
        if verified is None:
            print(
                f"WARNING: cannot verify {rel} (no/failed Proxmox query); "
                "trusting packer exit 0 — set PROXMOX_* to enable verification",
                file=sys.stderr,
            )
            return 0
        print(
            f"packer reported success but NO template found for {rel} "
            f"(attempt {attempt}/{attempts})",
            file=sys.stderr,
        )
        if attempt < attempts:
            time.sleep(RETRY_DELAY_SECONDS)

    return 1


def main() -> int:
    args = parse_args()
    ensure_venv_bin_on_path()
    root = repo_root()
    common_vars = root / "variables.auto.pkrvars.hcl"

    if not args.target:
        print(
            "Usage: build.py [--ask] [--overwrite] [--skip] "
            "[--init-only|--validate-only] [all|cloud|iso|all-linux|<build-dir>]"
        )
        return 1

    targets = resolve_targets(args.target)
    if not targets:
        print(f"Unknown build target: {args.target}", file=sys.stderr)
        print("Target keywords:", file=sys.stderr)
        print("  - all        cloud-image builds (default)", file=sys.stderr)
        print("  - cloud      same as 'all'", file=sys.stderr)
        print("  - iso        ISO/kickstart builds (opt-in)", file=sys.stderr)
        print("  - all-linux  cloud + ISO", file=sys.stderr)
        print("Available build targets:", file=sys.stderr)
        for build_dir in list_build_dirs():
            print(f"  - {build_dir}", file=sys.stderr)
        return 1

    # Keep going on failure: one flaky build must not abort the remaining
    # targets in a full run. Failures are reported at the end and the exit
    # code stays non-zero. init/validate still fail fast.
    failures: list[str] = []
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
                failures.append(build)
                print(f"BUILD FAILED (continuing): {build}", file=sys.stderr)
                continue
        if status != 0:
            return status
    if failures:
        print(f"FAILED BUILDS: {', '.join(failures)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
