#!/usr/bin/env bash
# Bootstrap a Windows cloud-base template from a Microsoft evaluation VHD/VHDX.
#
# Runs ON the Proxmox node (needs qm, kpartx and the ntfs3 kernel module).
# Idempotent-ish: refuses to clobber an existing VMID unless --force.
#
#   ./bootstrap-windows-base.sh \
#       --image /mnt/pve/iso_images/template/iso/ws2022-eval.vhd \
#       --vm-id 9422 --name windows-server-2022-desktop-experience-cloud-base \
#       --firmware seabios --win-part 1 --unattend /tmp/unattend.xml
#
# Why the unattend is injected offline
# ------------------------------------
# A vendor VHD has already been installed and generalised, so it resumes at the
# OOBE pass rather than running Windows Setup. Setup is what scans removable
# media for Autounattend.xml; OOBE does not. It reads a fixed set of on-disk
# locations instead, of which \Windows\Panther\unattend.xml is the usual choice.
# Attaching the answer file to a CD therefore does nothing and the image sits at
# "Hi there" forever — which is exactly what happened before this script existed.
#
# The injected file carries the Packer build credentials, so they are baked into
# the BASE template. The build's cleanup stage deletes
# C:\Windows\Panther\unattend.xml before sealing, so the shipped template does
# not carry them.
set -euo pipefail

IMAGE=""; VMID=""; NAME=""; FIRMWARE="seabios"; WINPART="1"; UNATTEND=""; FORCE=0
STORAGE="local-lvm"; BRIDGE="vmbr0"; VLAN="10"; MEM="8192"; CORES="4"

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --vm-id) VMID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --firmware) FIRMWARE="$2"; shift 2 ;;      # seabios | ovmf
    --win-part) WINPART="$2"; shift 2 ;;       # 1 for MBR 2022, 3 for GPT 2025
    --unattend) UNATTEND="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for v in IMAGE VMID NAME UNATTEND; do
  [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done
[ -s "$IMAGE" ]    || { echo "image not found: $IMAGE" >&2; exit 1; }
[ -s "$UNATTEND" ] || { echo "unattend not found: $UNATTEND" >&2; exit 1; }

if qm config "$VMID" >/dev/null 2>&1; then
  [ "$FORCE" = "1" ] || { echo "VMID $VMID exists; pass --force to replace" >&2; exit 1; }
  echo "==> removing existing $VMID"
  qm stop "$VMID" >/dev/null 2>&1 || true
  sleep 3
  qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >/dev/null
fi

# ostype win10 covers 2016/2019/2022; win11 is right for 2025.
OSTYPE="win10"; [ "$FIRMWARE" = "ovmf" ] && OSTYPE="win11"

echo "==> creating $VMID ($NAME) firmware=$FIRMWARE"
qm create "$VMID" --name "$NAME" \
  --machine q35 --bios "$FIRMWARE" --ostype "$OSTYPE" \
  --memory "$MEM" --cores "$CORES" --cpu host \
  --net0 "e1000,bridge=${BRIDGE},tag=${VLAN}" \
  --scsihw virtio-scsi-single --agent enabled=1 >/dev/null

[ "$FIRMWARE" = "ovmf" ] && \
  qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" >/dev/null

echo "==> importing $(basename "$IMAGE") (this is the slow part)"
qm importdisk "$VMID" "$IMAGE" "$STORAGE" >/dev/null

DISK=$(qm config "$VMID" | sed -n 's/^unused0: *//p')
[ -n "$DISK" ] || { echo "import produced no unused0" >&2; exit 1; }

# SATA, not virtio-scsi: the vendor image carries no virtio storage driver and
# would fail with INACCESSIBLE_BOOT_DEVICE. The build installs virtio in-guest
# and switch-template-to-virtio.py flips the bus afterwards.
qm set "$VMID" --sata0 "${DISK},discard=on,ssd=1" >/dev/null
qm set "$VMID" --boot order=sata0 >/dev/null
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" >/dev/null

LV="/dev/${STORAGE//-//}"                       # local-lvm -> /dev/local/lvm (wrong)
LV="/dev/pve/$(basename "${DISK#*:}")"          # local-lvm:vm-9422-disk-0 -> /dev/pve/vm-9422-disk-0
[ -b "$LV" ] || { echo "cannot find LV device for $DISK (looked at $LV)" >&2; exit 1; }

echo "==> injecting unattend into \\Windows\\Panther\\unattend.xml"
# qemu-nbd rather than kpartx: kpartx is not installed on a stock Proxmox node,
# and qemu-nbd is (it ships with qemu-utils). It maps a partitioned block device
# just as happily as an image file.
modprobe nbd max_part=8 2>/dev/null || true
modprobe ntfs3 2>/dev/null || true

NBD=""
for i in $(seq 0 15); do
  if ! [ -e "/sys/block/nbd$i/pid" ]; then NBD="/dev/nbd$i"; break; fi
done
[ -n "$NBD" ] || { echo "no free nbd device" >&2; exit 1; }

MNT=$(mktemp -d)
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

qemu-nbd --connect="$NBD" -f raw "$LV"
sleep 3
MAPPER="${NBD}p${WINPART}"
[ -b "$MAPPER" ] || { echo "partition $WINPART not found at $MAPPER" >&2; lsblk "$NBD" >&2; exit 1; }
mount -t ntfs3 "$MAPPER" "$MNT"
[ -d "$MNT/Windows" ] || { echo "partition $WINPART is not the Windows volume" >&2; exit 1; }

install -d "$MNT/Windows/Panther"
cp "$UNATTEND" "$MNT/Windows/Panther/unattend.xml"
echo "    wrote $(stat -c %s "$MNT/Windows/Panther/unattend.xml") bytes"
sync
cleanup
trap - EXIT

echo "==> converting to template"
qm template "$VMID" >/dev/null
echo "==> done: $VMID $NAME"
