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
import time
import urllib.parse

import requests
from proxmoxer import ProxmoxAPI, ResourceException
from proxmoxer.tools.tasks import Tasks


DEFAULT_IMAGE_URL = (
    "https://cloud-images.ubuntu.com/releases/noble/release/"
    "ubuntu-24.04-server-cloudimg-amd64.img"
)
DEFAULT_CHECKSUM_URL = "https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS"
DEFAULT_IMPORT_FILENAME = "ubuntu-24.04-server-cloudimg-amd64.qcow2"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap the Ubuntu cloud-image base template in Proxmox using the API."
    )
    parser.add_argument("--proxmox-url", default=os.environ.get("PROXMOX_URL"))
    parser.add_argument("--proxmox-user", default=os.environ.get("PROXMOX_USERNAME"))
    parser.add_argument("--proxmox-password", default=os.environ.get("PROXMOX_PASSWORD"))
    parser.add_argument("--node", default=os.environ.get("PROXMOX_NODE"))
    parser.add_argument("--target-storage", default=os.environ.get("PROXMOX_STORAGE"))
    parser.add_argument(
        "--import-storage",
        default=os.environ.get("PROXMOX_IMPORT_STORAGE"),
        help="File-based Proxmox storage with import content enabled.",
    )
    parser.add_argument("--base-vm-id", type=int, default=int(os.environ.get("PROXMOX_BASE_VM_ID", "9310")))
    parser.add_argument(
        "--base-template-name",
        default=os.environ.get("PROXMOX_BASE_TEMPLATE_NAME", "ubuntu-24-04-cloud-base"),
    )
    parser.add_argument("--bridge", default=os.environ.get("PROXMOX_BRIDGE", "vmbr0"))
    parser.add_argument("--vlan-tag", type=int, default=int(os.environ.get("PROXMOX_VLAN_TAG", "10")))
    parser.add_argument("--memory-mb", type=int, default=int(os.environ.get("PROXMOX_BASE_MEMORY_MB", "2048")))
    parser.add_argument("--cores", type=int, default=int(os.environ.get("PROXMOX_BASE_CORES", "2")))
    parser.add_argument("--image-url", default=os.environ.get("CLOUD_IMAGE_URL", DEFAULT_IMAGE_URL))
    parser.add_argument(
        "--checksum-url",
        default=os.environ.get("CLOUD_IMAGE_CHECKSUM_URL", DEFAULT_CHECKSUM_URL),
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(os.environ.get("PACKER_CACHE_DIR", "packer_cache")) / "ubuntu-cloud",
        help="Local metadata cache. The image itself is cached on Proxmox import storage.",
    )
    parser.add_argument("--import-filename", default=os.environ.get("PROXMOX_IMPORT_FILENAME", DEFAULT_IMPORT_FILENAME))
    parser.add_argument("--overwrite", action="store_true", default=os.environ.get("OVERWRITE_EXISTING") == "true")
    parser.add_argument("--refresh-image", action="store_true", help="Re-download the upstream image into import storage.")
    return parser.parse_args()


def require(value: str | None, name: str) -> str:
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def proxmox_client(url: str, user: str, password: str) -> ProxmoxAPI:
    parsed = urllib.parse.urlparse(url)
    if not parsed.scheme or not parsed.hostname:
        raise SystemExit(f"Invalid PROXMOX_URL: {url}")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return ProxmoxAPI(parsed.hostname, user=user, password=password, verify_ssl=False, port=port)


def read_checksum(checksum_url: str, image_url: str, cache_dir: Path) -> str:
    cache_dir.mkdir(parents=True, exist_ok=True)
    checksum_cache = cache_dir / "SHA256SUMS"
    image_name = Path(urllib.parse.urlparse(image_url).path).name

    if not checksum_cache.exists():
        response = requests.get(checksum_url, timeout=60)
        response.raise_for_status()
        checksum_cache.write_bytes(response.content)

    checksum_text = checksum_cache.read_text()
    for line in checksum_text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == image_name:
            return parts[0]

    checksum_cache.unlink(missing_ok=True)
    response = requests.get(checksum_url, timeout=60)
    response.raise_for_status()
    checksum_cache.write_bytes(response.content)
    checksum_text = checksum_cache.read_text()
    for line in checksum_text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == image_name:
            return parts[0]

    raise SystemExit(f"Unable to find checksum for {image_name} in {checksum_url}")


def wait_task(prox: ProxmoxAPI, upid: str, timeout: int = 1800) -> None:
    status = Tasks.blocking_status(prox, upid, timeout=timeout, polling_interval=2)
    if status is None:
        raise SystemExit(f"Timed out waiting for Proxmox task {upid}")
    if status.get("exitstatus") not in (None, "OK"):
        raise SystemExit(f"Proxmox task failed: {upid}: {status}")


def find_import_volume(prox: ProxmoxAPI, node: str, storage: str, filename: str) -> str | None:
    try:
        volumes = prox.nodes(node).storage(storage).content.get(content="import")
    except ResourceException as exc:
        raise SystemExit(
            f"Unable to list import content on storage {storage!r}. "
            "Ensure the storage supports and enables the 'import' content type."
        ) from exc

    for volume in volumes:
        volid = volume.get("volid", "")
        if volid.endswith(f"/{filename}") or volid.endswith(f":import/{filename}") or volid.endswith(filename):
            return volid
    return None


def select_import_storage(prox: ProxmoxAPI, requested_storage: str | None) -> str:
    if requested_storage:
        return requested_storage

    storages = prox.storage.get()
    candidates = [
        storage
        for storage in storages
        if "import" in storage.get("content", "").split(",")
    ]
    if not candidates:
        raise SystemExit(
            "No Proxmox storage has the 'import' content type enabled. "
            "Set PROXMOX_IMPORT_STORAGE after enabling import content on a file-backed storage."
        )

    shared_candidates = [storage for storage in candidates if int(storage.get("shared", 0)) == 1]
    selected = (shared_candidates or candidates)[0]["storage"]
    print(f"Using auto-selected Proxmox import storage {selected}")
    return selected


def delete_volume(prox: ProxmoxAPI, node: str, storage: str, volid: str) -> None:
    upid = prox.nodes(node).storage(storage).content(volid).delete()
    wait_task(prox, upid)


def ensure_import_volume(prox: ProxmoxAPI, args: argparse.Namespace, checksum: str) -> str:
    existing = find_import_volume(prox, args.node, args.import_storage, args.import_filename)
    if existing and not args.refresh_image:
        print(f"Using cached Proxmox import volume {existing}")
        return existing

    if existing:
        print(f"Removing stale cached import volume {existing}")
        delete_volume(prox, args.node, args.import_storage, existing)

    print(f"Downloading {args.image_url} to Proxmox storage {args.import_storage} as {args.import_filename}")
    upid = prox.nodes(args.node).storage(args.import_storage)("download-url").post(
        content="import",
        url=args.image_url,
        filename=args.import_filename,
        checksum=checksum,
        **{"checksum-algorithm": "sha256"},
    )
    wait_task(prox, upid)

    volid = find_import_volume(prox, args.node, args.import_storage, args.import_filename)
    if not volid:
        raise SystemExit(f"Downloaded image was not found in import storage {args.import_storage}")
    return volid


def vm_exists(prox: ProxmoxAPI, vmid: int) -> bool:
    resources = prox.cluster.resources.get(type="vm")
    return any(int(resource["vmid"]) == vmid for resource in resources if "vmid" in resource)


def destroy_vm(prox: ProxmoxAPI, node: str, vmid: int) -> None:
    try:
        prox.nodes(node).qemu(vmid).status.stop.post()
        time.sleep(2)
    except ResourceException:
        pass

    upid = prox.nodes(node).qemu(vmid).delete(
        purge=1,
        **{"destroy-unreferenced-disks": 1},
    )
    wait_task(prox, upid)


def create_base_template(prox: ProxmoxAPI, args: argparse.Namespace, import_volid: str) -> None:
    if vm_exists(prox, args.base_vm_id):
        if not args.overwrite:
            raise SystemExit(
                f"VMID {args.base_vm_id} already exists. Re-run with --overwrite or set OVERWRITE_EXISTING=true."
            )
        print(f"Destroying existing VM/template {args.base_vm_id}")
        destroy_vm(prox, args.node, args.base_vm_id)

    print(f"Creating base template {args.base_template_name} ({args.base_vm_id})")
    create_params = {
        "vmid": args.base_vm_id,
        "name": args.base_template_name,
        "memory": args.memory_mb,
        "cores": args.cores,
        "sockets": 1,
        "cpu": "host",
        "machine": "q35",
        "bios": "ovmf",
        "ostype": "l26",
        "scsihw": "virtio-scsi-pci",
        "agent": "enabled=1,fstrim_cloned_disks=1",
        "hotplug": "network,disk,cpu,memory,usb",
        "numa": 1,
        "serial0": "socket",
        "vga": "serial0",
        "net0": f"virtio,bridge={args.bridge},tag={args.vlan_tag}",
        "efidisk0": f"{args.target_storage}:1,efitype=4m,pre-enrolled-keys=1",
        "scsi0": f"{args.target_storage}:0,import-from={import_volid},discard=on,ssd=1",
        "ide2": f"{args.target_storage}:cloudinit",
        "boot": "order=scsi0",
        "ipconfig0": "ip=dhcp",
        "description": "Ubuntu 24.04 cloud image base template for Packer proxmox-clone builds",
    }
    upid = prox.nodes(args.node).qemu.post(**create_params)
    wait_task(prox, upid)

    upid = prox.nodes(args.node).qemu(args.base_vm_id).template.post()
    wait_task(prox, upid)


def main() -> int:
    args = parse_args()
    args.proxmox_url = require(args.proxmox_url, "PROXMOX_URL")
    args.proxmox_user = require(args.proxmox_user, "PROXMOX_USERNAME")
    args.proxmox_password = require(args.proxmox_password, "PROXMOX_PASSWORD")
    args.node = require(args.node, "PROXMOX_NODE")
    args.target_storage = require(args.target_storage, "PROXMOX_STORAGE")

    checksum = read_checksum(args.checksum_url, args.image_url, args.cache_dir)
    prox = proxmox_client(args.proxmox_url, args.proxmox_user, args.proxmox_password)
    args.import_storage = select_import_storage(prox, args.import_storage)
    import_volid = ensure_import_volume(prox, args, checksum)
    create_base_template(prox, args, import_volid)
    print(f"Base template ready: {args.base_template_name} ({args.base_vm_id})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
