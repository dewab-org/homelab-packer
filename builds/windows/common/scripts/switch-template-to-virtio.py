#!/usr/bin/env python3
"""Flip a freshly built Windows template from SATA/e1000 to virtio-scsi/virtio-net.

Why this exists
---------------
A Microsoft evaluation VHD/VHDX carries no virtio drivers. Booting it on a
virtio-scsi disk fails with INACCESSIBLE_BOOT_DEVICE, because Windows needs
viostor/vioscsi loaded in the boot path *before* the OS starts and cannot
install a driver from a disk it is unable to read. The ISO builds avoid this by
loading drivers during Setup's windowsPE phase; a prebuilt image never runs
Setup, so the base template must boot on SATA with an e1000 NIC.

DOES NOT CURRENTLY WORK — disabled by default (switch_to_virtio = false).

The theory was that once 03-install-virtio-guest-tools.ps1 had put
viostor/vioscsi/netkvm in the driver store, the disk could simply be moved to
the virtio-scsi controller. It cannot: a clone of the switched template boots
straight into the Windows Recovery Environment. Having the driver in the store
is not the same as having the storage controller registered boot-critical, so
Windows cannot find its system disk on the new bus.

Making this work needs the controller present at boot *before* the switch —
attach a scratch virtio-scsi disk during the build so Windows enumerates the
controller and activates the driver, then move the system disk and drop the
scratch. Until that is implemented and verified end to end, templates ship on
SATA/e1000, which is fine for the test VMs these are for.

The script itself is correct and idempotent (verified with --dry-run); it is the
premise above that was wrong.

Reads PROXMOX_URL / PROXMOX_USERNAME / PROXMOX_PASSWORD / PROXMOX_NODE /
PROXMOX_VM_ID from the environment, as supplied by the packer shell-local
post-processor, matching builds/linux/common/scripts/finalize-template-config.py.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

if __name__ == "__main__":
    repo_root = next(
        (p for p in Path(__file__).resolve().parents if (p / ".venv").is_dir()),
        Path(__file__).resolve().parents[4],
    )
    venv_python = repo_root / ".venv" / "bin" / "python3"
    if venv_python.is_file() and os.access(venv_python, os.X_OK) and sys.executable != str(venv_python):
        os.execv(str(venv_python), [str(venv_python)] + sys.argv)

import argparse
import re
import urllib.parse

from proxmoxer import ProxmoxAPI


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxmox-url", default=os.environ.get("PROXMOX_URL"))
    parser.add_argument("--proxmox-user", default=os.environ.get("PROXMOX_USERNAME"))
    parser.add_argument("--proxmox-password", default=os.environ.get("PROXMOX_PASSWORD"))
    parser.add_argument("--node", default=os.environ.get("PROXMOX_NODE"))
    parser.add_argument("--vm-id", type=int, default=int(os.environ.get("PROXMOX_VM_ID", "0")))
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the change without applying it",
    )
    return parser.parse_args()


def require(value, name: str):
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


def main() -> int:
    args = parse_args()

    # Honour the flag here rather than in the post-processor's `only`, which
    # cannot express "never" (an empty list disables filtering entirely).
    if os.environ.get("SWITCH_TO_VIRTIO", "true").strip().lower() in ("false", "0", "no"):
        print("SWITCH_TO_VIRTIO is false; leaving the template on SATA/e1000.")
        return 0

    prox = proxmox_client(
        require(args.proxmox_url, "PROXMOX_URL"),
        require(args.proxmox_user, "PROXMOX_USERNAME"),
        require(args.proxmox_password, "PROXMOX_PASSWORD"),
    )
    vm_id = int(require(args.vm_id, "PROXMOX_VM_ID"))
    node = find_vm_node(prox, vm_id, args.node)
    vm = prox.nodes(node).qemu(vm_id)
    config = vm.config.get()

    sata0 = config.get("sata0")
    if not sata0:
        # Already virtio (idempotent re-run), or an unexpected layout. Either way
        # there is nothing safe to move, so say so rather than guessing.
        print(f"VMID {vm_id}: no sata0 disk; leaving disk bus unchanged "
              f"(scsi0={config.get('scsi0', 'absent')})")
        disk_changed = False
    else:
        # sata0 looks like "local-lvm:base-9432-disk-1,discard=on,size=40G,ssd=1".
        # Keep every option except the ones the scsi controller re-derives.
        volume, _, opts = sata0.partition(",")
        kept = [o for o in opts.split(",") if o and not o.startswith("size=")]
        scsi0 = ",".join([volume] + kept + ["iothread=1"])
        if args.dry_run:
            print(f"VMID {vm_id}: would move {volume} sata0 -> scsi0 ({scsi0})")
        else:
            vm.config.put(scsi0=scsi0, delete="sata0", scsihw="virtio-scsi-single")
            print(f"VMID {vm_id}: disk moved sata0 -> scsi0 (virtio-scsi-single)")
        disk_changed = True

    net0 = config.get("net0", "")
    if net0.startswith("virtio"):
        print(f"VMID {vm_id}: net0 already virtio")
    elif net0:
        # net0 looks like "e1000=BC:24:11:...,bridge=vmbr0,tag=10". Preserve the
        # MAC so the template's clones keep predictable addressing behaviour.
        model_mac, _, rest = net0.partition(",")
        _, _, mac = model_mac.partition("=")
        new_net = ",".join([f"virtio={mac}" if mac else "virtio"] + ([rest] if rest else []))
        if args.dry_run:
            print(f"VMID {vm_id}: would set net0 {net0} -> {new_net}")
        else:
            vm.config.put(net0=new_net)
            print(f"VMID {vm_id}: net0 e1000 -> virtio")

    if disk_changed and not args.dry_run:
        # Unconditionally point boot at scsi0. The old code only rewrote the
        # order when it already mentioned sata0 — but Packer leaves the finished
        # template booting from the virtio CD (sata1), so the condition never
        # matched and the template was left booting from a device that no longer
        # exists. Observed: clone hung at the SeaBIOS splash.
        vm.config.put(boot="order=scsi0")
        print(f"VMID {vm_id}: boot order set to scsi0")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
