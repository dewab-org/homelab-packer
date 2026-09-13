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

# Builds never land on the template's own VMID. Packer builds at
# vm_id + SCRATCH_OFFSET; the result is verified (template flag, then a real
# clone-boot via tests/clone-verify.py); only THEN is the live template replaced
# by a full clone back onto its stable VMID, and the scratch copy deleted.
#
# This exists because the previous design - packer -force straight onto the
# target - destroys the working template as its FIRST act and then spends two
# hours building the replacement. Both Windows cloud templates were lost that
# way (9432 on 2026-09-12, 9434 on 2026-08-23): the rebuilds hung, the jobs were
# killed at their timeout, and nothing was left behind but a half-built VM.
#
# +10000 rather than a neighbouring number: tests/clone-verify.py owns
# 9600-9699 for its throwaway clones, and nothing in the estate lives above
# 9500, so 19xxx is unmistakably scratch and cannot collide with either.
SCRATCH_OFFSET = 10000


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
        "Retries also fire when packer exits 0 but no template is found at the "
        "scratch VMID. Ignored with --ask/--init-only/--validate-only.",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="skip the clone-boot verification (tests/clone-verify.py) of the new "
        "template before it replaces the live one. The cheap check that packer "
        "actually produced a template is never skipped - promotion depends on it.",
    )
    exclusive = parser.add_mutually_exclusive_group()
    exclusive.add_argument(
        "--overwrite",
        action="store_true",
        help="allow an existing template at the target VMID to be replaced. The "
        "replacement happens only after the new build is verified; without this "
        "flag a build whose target already exists is refused up front rather "
        "than two hours in.",
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

    Windows is excluded from every keyword on purpose: each Windows ISO build
    is a full Windows Setup plus Windows Update, about two hours, so a keyword
    that swept them in would turn a quick Linux pass into an all-day one. CI
    dispatches them individually (see .github/workflows/build-templates.yml);
    locally, name the directory: ./build.py builds/windows/<name>.
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


def scratch_vm_id(vm_id: str) -> str:
    return str(int(vm_id) + SCRATCH_OFFSET)


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
        # A full clone of an 80G template is one long-running API call.
        timeout=120,
    )


def find_vm(prox, vm_id: str) -> dict | None:
    """The cluster resource entry for a VMID, or None when nothing is there.

    Raises on a failed query (deliberately): callers that promote or destroy
    must not mistake "Proxmox did not answer" for "the VMID is free".
    """
    for entry in prox.cluster.resources.get(type="vm"):
        if str(entry.get("vmid")) == str(vm_id):
            return entry
    return None


def is_template(entry: dict | None) -> bool:
    return entry is not None and int(entry.get("template", 0) or 0) == 1


def vm_config(prox, node: str, vm_id: str) -> dict | None:
    """The VM's live config from its node, or None if it does not exist.

    cluster/resources is a CACHE refreshed by pvestatd every few seconds. Its
    `template` flag lagged a full second behind a completed template task in
    testing, and a destroyed VM lingers in it just as long. The node's config
    endpoint is authoritative, so every irreversible decision below reads this
    instead.
    """
    try:
        return prox.nodes(node).qemu(vm_id).config.get()
    except Exception as exc:
        text = str(exc).lower()
        if "does not exist" in text or "no such" in text or "500" in text:
            return None
        raise


def is_template_now(prox, entry: dict | None) -> bool:
    """Authoritative template check for a cluster-resources entry."""
    if entry is None:
        return False
    cfg = vm_config(prox, entry["node"], entry["vmid"])
    return cfg is not None and int(cfg.get("template", 0) or 0) == 1


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
    """Confirm a Proxmox *template* exists at the build's target VMID.

    Used only by the legacy direct-build path (no Proxmox credentials at build
    time, see run_build) and by callers outside this file. Matches on VMID or
    name and requires the template flag.

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


def base_status(clone_vm_id: str, target_size: str) -> int:
    """Report a clone-source base's state as an exit code (for CI).

    0 = present and the OS disk is target_size (or Proxmox is unqueryable, so
    the build proceeds and its own verify catches problems); 3 = missing;
    4 = present but the disk is not target_size (undersized). Prints a note.
    """
    prox = proxmox_client()
    if prox is None:
        print("cannot query Proxmox; proceeding")
        return 0
    try:
        entry = next(
            (e for e in prox.cluster.resources.get(type="vm")
             if str(e.get("vmid")) == str(clone_vm_id)),
            None,
        )
    except Exception:
        print("cannot query Proxmox; proceeding")
        return 0
    if entry is None:
        print("MISSING")
        return 3
    scsi0 = prox.nodes(entry.get("node")).qemu(clone_vm_id).config.get().get("scsi0", "")
    if f"size={target_size}" in scsi0:
        print(f"OK ({scsi0})")
        return 0
    print(f"UNDERSIZED (scsi0={scsi0}, want size={target_size})")
    return 4


def _wait_proxmox_task(prox, node: str, upid, timeout: int = 300) -> str:
    """Poll a Proxmox task UPID until it stops and return its exit status.

    Returns "OK" on success, the task's own error text on failure, or
    "TIMEOUT"/"UNKNOWN" when the outcome could not be read. Callers doing
    anything irreversible must check the return value: a clone that "finished"
    with an error is not a clone.
    """
    if not upid:
        return "UNKNOWN"
    end = time.time() + timeout
    while time.time() < end:
        try:
            status = prox.nodes(node).tasks(upid).status.get()
        except Exception:
            time.sleep(2)
            continue
        if status.get("status") == "stopped":
            return str(status.get("exitstatus", "UNKNOWN"))
        time.sleep(2)
    return "TIMEOUT"


def stop_and_destroy(prox, entry: dict, why: str) -> bool:
    """Stop (if running) and destroy the VM or template in `entry`."""
    vm_id = entry.get("vmid")
    node = entry.get("node")
    # The entry came from the cluster cache; a VM destroyed seconds ago can
    # still be listed. Confirm it is really there before touching anything.
    cfg = vm_config(prox, node, vm_id)
    if cfg is None:
        print(f"  {vm_id} is already gone (stale cache entry)")
        return True
    kind = "template" if int(cfg.get("template", 0) or 0) == 1 else "VM"
    print(f"destroying {kind} {vm_id} '{entry.get('name', '')}' on {node}: {why}", flush=True)
    try:
        status = prox.nodes(node).qemu(vm_id).status.current.get().get("status")
        if status == "running":
            _wait_proxmox_task(prox, node, prox.nodes(node).qemu(vm_id).status.stop.post())
        result = _wait_proxmox_task(prox, node, prox.nodes(node).qemu(vm_id).delete(purge=1))
    except Exception as exc:
        print(f"  ERROR: could not destroy {vm_id}: {exc}", file=sys.stderr)
        return False
    if result != "OK":
        print(f"  ERROR: destroy task for {vm_id} ended '{result}'", file=sys.stderr)
        return False
    print(f"  destroyed {vm_id}")
    return True


def purge_stranded_build_vm(build_vars: Path) -> None:
    """Legacy-path helper: remove a non-template VM squatting on the target VMID.

    Only the direct-build fallback (no Proxmox credentials) can strand a VM on
    the target; the scratch-and-swap path clears its own scratch VMID instead.
    A real *template* on the VMID is left alone here.
    """
    vm_id = parse_vm_id(build_vars)
    if not vm_id:
        return
    prox = proxmox_client()
    if prox is None:
        return
    try:
        entry = find_vm(prox, vm_id)
    except Exception:
        return
    if entry is None or is_template(entry):
        return
    stop_and_destroy(prox, entry, "stranded non-template VM on the target VMID would block the build")


def clear_scratch(prox, scratch: str) -> bool:
    """Make the scratch VMID free. Anything there is ours by construction."""
    try:
        entry = find_vm(prox, scratch)
    except Exception as exc:
        print(f"ERROR: cannot query Proxmox for scratch VMID {scratch}: {exc}", file=sys.stderr)
        return False
    if entry is None:
        return True
    return stop_and_destroy(prox, entry, "leftover from an earlier attempt at the scratch VMID")


def run_clone_verify(vm_id: str) -> bool:
    """Boot a throwaway clone of the template at vm_id and check it from inside.

    Delegates to tests/clone-verify.py - the same check CI runs after a build -
    so the new template is exercised BEFORE it replaces the live one.
    """
    script = repo_root() / "tests" / "clone-verify.py"
    if not script.exists():
        print(f"ERROR: {script} is missing; cannot verify the new template", file=sys.stderr)
        return False
    print(f"===== CLONE-VERIFY scratch template {vm_id} =====", flush=True)
    return run_command([sys.executable, str(script), str(vm_id)]) == 0


def promote_scratch(prox, scratch: str, target: str) -> bool:
    """Replace the live template at `target` with the verified one at `scratch`.

    Order matters and is the whole point:
      1. the scratch template already exists and has been verified;
      2. ONLY NOW is the old template at `target` destroyed;
      3. the scratch is full-cloned onto `target` (stable VMID, same name);
      4. the copy is converted to a template and checked;
      5. the scratch is deleted.
    The live template is unavailable only between 2 and 4 - minutes, for a
    disk copy - instead of for the whole build. If anything after step 2 fails
    the scratch is LEFT IN PLACE and named in the error, so the work is not
    lost and can be promoted by hand.
    """
    entry = find_vm(prox, scratch)
    if not is_template_now(prox, entry):
        print(f"ERROR: no template at scratch VMID {scratch}; nothing to promote", file=sys.stderr)
        return False
    node = entry["node"]
    # Packer already gave the scratch the right name; carry it over verbatim.
    # A clone without `name` would be called "Copy-of-VM-<name>".
    name = entry.get("name") or None

    old = find_vm(prox, target)
    if old is not None:
        if not stop_and_destroy(prox, old, f"being replaced by verified scratch template {scratch}"):
            print(f"ERROR: could not remove the old template at {target}; scratch {scratch} left in place",
                  file=sys.stderr)
            return False

    print(f"promoting: full clone {scratch} -> {target}" + (f" ({name})" if name else ""), flush=True)
    params = {"newid": int(target), "full": 1}
    if name:
        params["name"] = name
    try:
        result = _wait_proxmox_task(prox, node, prox.nodes(node).qemu(scratch).clone.post(**params), timeout=3600)
    except Exception as exc:
        result = f"exception: {exc}"
    if result != "OK":
        print(f"ERROR: clone {scratch} -> {target} ended '{result}'; scratch {scratch} left in place "
              f"(the old template at {target} is already gone - promote the scratch by hand)", file=sys.stderr)
        return False

    try:
        result = _wait_proxmox_task(prox, node, prox.nodes(node).qemu(target).template.post(), timeout=600)
    except Exception as exc:
        result = f"exception: {exc}"
    if result != "OK":
        print(f"ERROR: converting {target} to a template ended '{result}'; scratch {scratch} left in place",
              file=sys.stderr)
        return False

    new = find_vm(prox, target)
    if not is_template_now(prox, new):
        print(f"ERROR: {target} is not a template after promotion; scratch {scratch} left in place",
              file=sys.stderr)
        return False

    if not stop_and_destroy(prox, entry, "scratch copy no longer needed after promotion"):
        # Not fatal: the live template is in place. Say so and let it be cleaned
        # up by the next build's clear_scratch().
        print(f"WARNING: scratch {scratch} could not be deleted; the next build will clear it",
              file=sys.stderr)
    print(f"promoted: template {target}" + (f" '{name}'" if name else "") + f" replaced from {scratch}")
    return True


def build_packer_args(
    build_dir: Path,
    common_vars: Path,
    build_vars: Path,
    ssh_private_key_file: str | None = None,
    ssh_public_key_build: str | None = None,
    vm_id_override: str | None = None,
) -> list[str]:
    packer_args = []
    packer_args.append(f"-var-file={common_vars}")
    if build_vars.exists():
        packer_args.append(f"-var-file={build_vars}")
    if ssh_private_key_file:
        packer_args.append(f"-var=ssh_private_key_file={ssh_private_key_file}")
    if ssh_public_key_build:
        packer_args.append(f"-var=ssh_public_key_build={ssh_public_key_build}")
    # After the var-files on purpose: a later -var wins over an earlier
    # -var-file, which is how the scratch VMID displaces the one in the pkrvars.
    if vm_id_override:
        packer_args.append(f"-var=vm_id={vm_id_override}")
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
    force: bool = False,
    vm_id_override: str | None = None,
) -> int:
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    ssh_private_key_file, ssh_public_key_build, ssh_key_tmpdir = generate_build_ssh_keypair()
    try:
        packer_args = ["packer", "build"]
        if args.ask:
            packer_args.append("-on-error=ask")
        if force:
            packer_args.append("-force")
        packer_args.extend(build_packer_args(
            build_dir, common_vars, build_vars, ssh_private_key_file, ssh_public_key_build, vm_id_override
        ))
        return run_command(packer_args)
    finally:
        shutil.rmtree(ssh_key_tmpdir, ignore_errors=True)


def _attempt_banner(attempt: int, attempts: int, rel: Path) -> None:
    if attempt > 1:
        print(
            f"===== RETRY {attempt - 1}/{attempts - 1} for {rel} "
            f"(waited {RETRY_DELAY_SECONDS}s) =====",
            flush=True,
        )


def run_build_direct(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    """The old behaviour: packer builds straight onto the target VMID.

    Kept ONLY for runs without Proxmox credentials, where nothing can be
    queried, cloned or promoted. It carries the old hazard - with --overwrite,
    `packer -force` destroys the existing template before building - and says
    so out loud rather than pretending otherwise.
    """
    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    rel = build_dir.relative_to(repo_root())
    print(
        "WARNING: PROXMOX_URL/USERNAME/PASSWORD not set - building DIRECTLY on the "
        "target VMID. With --overwrite this destroys the existing template BEFORE "
        "the new one exists. Export the PROXMOX_* variables to get the "
        "scratch-and-swap path instead.",
        file=sys.stderr,
    )
    attempts = 1 if args.ask else 1 + max(0, args.retries)
    for attempt in range(1, attempts + 1):
        _attempt_banner(attempt, attempts, rel)
        purge_stranded_build_vm(build_vars)
        # Retries must overwrite whatever a failed attempt left behind.
        status = run_packer(build_dir, common_vars, args, force=(args.overwrite or attempt > 1))
        if status != 0:
            print(f"packer build exited {status} for {rel} (attempt {attempt}/{attempts})", file=sys.stderr)
            if attempt < attempts:
                time.sleep(RETRY_DELAY_SECONDS)
            continue
        verified = verify_template_built(build_dir, build_vars)
        if verified is True:
            print(f"verified: template for {rel} is present in Proxmox")
            return 0
        if verified is None:
            print(f"WARNING: cannot verify {rel} (no Proxmox query); trusting packer exit 0", file=sys.stderr)
            return 0
        print(f"packer reported success but NO template found for {rel} (attempt {attempt}/{attempts})",
              file=sys.stderr)
        if attempt < attempts:
            time.sleep(RETRY_DELAY_SECONDS)
    return 1


def run_build(build_dir: Path, common_vars: Path, args: argparse.Namespace) -> int:
    print(f"===== BUILDING {build_dir} =====", flush=True)
    if not build_dir.is_dir():
        print(f"Unknown build directory: {build_dir}", file=sys.stderr)
        return 1
    if not common_vars.exists():
        print(f"Missing common vars: {common_vars}", file=sys.stderr)
        return 1

    build_vars = build_dir / "variables.auto.pkrvars.hcl"
    rel = build_dir.relative_to(repo_root())

    if args.skip:
        exists = template_exists(build_dir, build_vars)
        if exists is True:
            print(f"Skipping {rel} (template already exists)")
            return 0
        if exists is None:
            print(f"Skip requested but unable to query Proxmox; proceeding with {rel}", file=sys.stderr)

    target = parse_vm_id(build_vars)
    prox = proxmox_client()
    if prox is None or not target:
        if not target:
            print(f"NOTE: {rel} declares no vm_id; the scratch-and-swap path needs one", file=sys.stderr)
        return run_build_direct(build_dir, common_vars, args)

    # Refuse up front, not two hours in: replacing a live template is the one
    # irreversible thing this script does, and it needs to have been asked for.
    try:
        current = find_vm(prox, target)
    except Exception as exc:
        print(f"ERROR: cannot query Proxmox for {target}: {exc}", file=sys.stderr)
        return 1
    if current is not None and not args.overwrite:
        what = "template" if is_template(current) else "non-template VM"
        print(
            f"ERROR: a {what} already exists at VMID {target} ('{current.get('name', '')}'). "
            "Pass --overwrite to replace it (only after the new build is verified) "
            "or --skip to leave it.",
            file=sys.stderr,
        )
        return 1

    scratch = scratch_vm_id(target)
    print(f"building at scratch VMID {scratch}; live template {target} is untouched until the result is verified",
          flush=True)

    # --ask hands control to packer's interactive on-error prompt, so an
    # unattended retry loop would fight it; run exactly once in that mode.
    attempts = 1 if args.ask else 1 + max(0, args.retries)
    built = False
    for attempt in range(1, attempts + 1):
        _attempt_banner(attempt, attempts, rel)
        if not clear_scratch(prox, scratch):
            return 1
        # -force is always on for the scratch VMID: it is ours, and a retry
        # must be able to replace whatever the previous attempt left there.
        status = run_packer(build_dir, common_vars, args, force=True, vm_id_override=scratch)
        if status != 0:
            print(f"packer build exited {status} for {rel} (attempt {attempt}/{attempts})", file=sys.stderr)
            if attempt < attempts:
                time.sleep(RETRY_DELAY_SECONDS)
            continue
        # Exit 0 is a claim, not proof: there must be a TEMPLATE at the scratch VMID.
        try:
            entry = find_vm(prox, scratch)
        except Exception as exc:
            print(f"ERROR: cannot query Proxmox after the build: {exc}", file=sys.stderr)
            return 1
        if not is_template_now(prox, entry):
            print(
                f"packer reported success but there is no template at scratch VMID {scratch} "
                f"for {rel} (attempt {attempt}/{attempts})",
                file=sys.stderr,
            )
            if attempt < attempts:
                time.sleep(RETRY_DELAY_SECONDS)
            continue
        print(f"verified: template present at scratch VMID {scratch}")
        built = True
        break

    if not built:
        print(f"no usable template produced for {rel}; live template {target} untouched", file=sys.stderr)
        return 1

    if args.no_verify:
        print("NOTE: --no-verify - skipping the clone-boot check before promotion", file=sys.stderr)
    elif not run_clone_verify(scratch):
        print(
            f"clone-verify FAILED for scratch template {scratch}; live template {target} untouched. "
            f"The scratch is left in place for inspection.",
            file=sys.stderr,
        )
        return 1

    if not promote_scratch(prox, scratch, target):
        return 1
    print(f"verified: template for {rel} is live at {target}")
    return 0


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
