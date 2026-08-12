# Windows Server 2022 (Evaluation) ISO — build 20348, SERVER_EVAL x64 en-us.
# Same single-ISO/both-editions arrangement as 2025: windows_image_index below
# selects Core (1) vs Desktop Experience (2). Mirrored in the lab at:
# iso_url = "https://web.viking.org/cdimages/Microsoft/windows-server-2022-eval-x64-en-us-20348.169.iso"
iso_file = "iso_images:iso/windows-server-2022-eval-x64-en-us-20348.169.iso"
# iso_checksum is unused when iso_file is set (the ISO already lives in storage).

# VirtIO drivers + guest tools ISO.
virtio_iso_file = "iso_images:iso/virtio-win-0.1.285.iso"

bridge = "vmbr0"

# Windows-specific locale/timezone variables (do not use ks_* here).
win_language = "en-US"
win_keyboard = "en-US"
win_timezone = "Central Standard Time"

vm_id = 9411

# Pin Core explicitly so this build cannot drift if the shared default changes.
windows_image_index = 1

# Build and land this template on the NFS datastore rather than the node's
# local-lvm thin pool. local-lvm sits ~86% full with 48 volumes on it, and an
# 80G Windows build is a poor neighbour there; nas-datastore01 has ~10.6TB free
# and is NFS 4.2, so discard=on in the build can actually reclaim space.
storage_pool = "nas-datastore01"

# Cloudbase-Init is what makes a CLONE configure itself (hostname, user,
# network) - 60-install-cloudbase-init.ps1 throws if this is unset rather than
# silently shipping a template whose clones never run cloud-init. Same version
# and checksum as the cloud builds, deliberately: a template should not differ
# by how it was installed.
cloudbase_init_url      = "https://github.com/cloudbase/cloudbase-init/releases/download/1.1.8/CloudbaseInitSetup_1_1_8_x64.msi"
cloudbase_init_checksum = "sha256:0e7fa42e0cbc0ce7657f85730b0c6cc7afc4087a3639df0ff51a721a0be19bd5"
