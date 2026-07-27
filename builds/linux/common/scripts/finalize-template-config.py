#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

if __name__ == "__main__":
    repo_root = Path(__file__).resolve().parents[5]
    venv_python = repo_root / ".venv" / "bin" / "python3"
    if venv_python.is_file() and os.access(venv_python, os.X_OK) and sys.executable != str(venv_python):
        os.execv(str(venv_python), [str(venv_python)] + sys.argv)

import argparse
import re
import urllib.parse

from proxmoxer.tools.tasks import Tasks
from proxmoxer import ProxmoxAPI


TARGET_DISK_SIZE_MIB = 60 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Apply final cloud-init defaults to a Proxmox template VM.")
    parser.add_argument("--proxmox-url", default=os.environ.get("PROXMOX_URL"))
    parser.add_argument("--proxmox-user", default=os.environ.get("PROXMOX_USERNAME"))
    parser.add_argument("--proxmox-password", default=os.environ.get("PROXMOX_PASSWORD"))
    parser.add_argument("--node", default=os.environ.get("PROXMOX_NODE"))
    parser.add_argument("--vm-id", type=int, default=int(os.environ.get("PROXMOX_VM_ID", "0")))
    return parser.parse_args()


def require(value: str | int | None, name: str) -> str | int:
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def proxmox_client(url: str, user: str, password: str) -> ProxmoxAPI:
    parsed = urllib.parse.urlparse(url)
    if not parsed.scheme or not parsed.hostname:
        raise SystemExit(f"Invalid PROXMOX_URL: {url}")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return ProxmoxAPI(parsed.hostname, user=user, password=password, verify_ssl=False, port=port)


def find_vm_node(prox: ProxmoxAPI, vm_id: int, requested_node: str | None) -> str:
    if requested_node:
        return requested_node

    for resource in prox.cluster.resources.get(type="vm"):
        if int(resource.get("vmid", -1)) == vm_id:
            return resource["node"]

    raise SystemExit(f"Unable to find VMID {vm_id}")


def parse_disk_size_to_mib(config_value: str | None) -> int | None:
    if not config_value:
        return None

    match = re.search(r"size=(\d+)([KMGTP])", config_value)
    if not match:
        return None

    amount = int(match.group(1))
    unit = match.group(2)
    multipliers = {
        "K": 1 / 1024,
        "M": 1,
        "G": 1024,
        "T": 1024 * 1024,
        "P": 1024 * 1024 * 1024,
    }
    return int(amount * multipliers[unit])


def wait_task(prox: ProxmoxAPI, upid: str, timeout: int = 1800) -> None:
    status = Tasks.blocking_status(prox, upid, timeout=timeout, polling_interval=2)
    if status is None:
        raise SystemExit(f"Timed out waiting for Proxmox task {upid}")
    if status.get("exitstatus") not in (None, "OK"):
        raise SystemExit(f"Proxmox task failed: {upid}: {status}")


def ensure_disk_size(prox: ProxmoxAPI, node: str, vm_id: int) -> None:
    config = prox.nodes(node).qemu(vm_id).config.get()
    current_size_mib = parse_disk_size_to_mib(config.get("scsi0"))
    if current_size_mib is None:
        raise SystemExit(f"Unable to determine current scsi0 size for VMID {vm_id}")

    if current_size_mib >= TARGET_DISK_SIZE_MIB:
        print(f"VMID {vm_id} disk already at {current_size_mib} MiB or larger")
        return

    delta_mib = TARGET_DISK_SIZE_MIB - current_size_mib
    print(f"Resizing VMID {vm_id} scsi0 from {current_size_mib} MiB to {TARGET_DISK_SIZE_MIB} MiB")
    upid = prox.nodes(node).qemu(vm_id).resize.set(disk="scsi0", size=f"+{delta_mib}M")
    if upid:
        wait_task(prox, upid)


def main() -> int:
    args = parse_args()
    proxmox_url = require(args.proxmox_url, "PROXMOX_URL")
    proxmox_user = require(args.proxmox_user, "PROXMOX_USERNAME")
    proxmox_password = require(args.proxmox_password, "PROXMOX_PASSWORD")
    vm_id = int(require(args.vm_id, "PROXMOX_VM_ID"))

    prox = proxmox_client(str(proxmox_url), str(proxmox_user), str(proxmox_password))
    node = find_vm_node(prox, vm_id, args.node)
    ensure_disk_size(prox, node, vm_id)
    prox.nodes(node).qemu(vm_id).config.put(
        ipconfig0="ip=dhcp",
        agent="enabled=1,fstrim_cloned_disks=1",
        hotplug="network,disk,cpu,memory,usb",
        numa=1,
    )
    print(f"Finalized VMID {vm_id} cloud-init defaults: ipconfig0=ip=dhcp, disk={TARGET_DISK_SIZE_MIB} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
