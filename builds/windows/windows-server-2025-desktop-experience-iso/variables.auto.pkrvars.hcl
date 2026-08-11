# Windows Server 2025 (Evaluation) ISO.
# Use iso_url (downloaded/cached by Packer) unless you explicitly set iso_file.
# iso_url = "https://web.viking.org/cdimages/Microsoft/windows-server-2025-eval-x64-en-us-26100.32230.iso"
iso_file     = "iso_images:iso/windows-server-2025-eval-x64-en-us-26100.32230.iso"
iso_checksum = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"

# VirtIO drivers + guest tools ISO.
virtio_iso_file = "iso_images:iso/virtio-win-0.1.285.iso"
# virtio_iso_checksum = "sha256:e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331"

bridge = "vmbr0"

# Windows-specific locale/timezone variables (do not use ks_* here).
win_language = "en-US"
win_keyboard = "en-US"
win_timezone = "Central Standard Time"

# Optional, but recommended to keep stable VMIDs per template.
# 9403, not 9402: an earlier desktop-experience build landed at 9402
# (2026-03-12) and was superseded by a rebuild at 9403 (2026-03-14) that took
# the canonical name. The repo tracks the live template rather than renumbering
# it. 9402 is free. See README "Windows VMID map".
vm_id = 9403

# Pin Desktop Experience explicitly. On the current Server 2025 eval ISO,
# index 2 is Standard Desktop Experience while index 1 is Standard Core.
windows_image_index = 2

# Build and land this template on the NFS datastore rather than the node's
# local-lvm thin pool. local-lvm sits ~86% full with 48 volumes on it, and an
# 80G Windows build is a poor neighbour there; nas-datastore01 has ~10.6TB free
# and is NFS 4.2, so discard=on in the build can actually reclaim space.
storage_pool = "nas-datastore01"
