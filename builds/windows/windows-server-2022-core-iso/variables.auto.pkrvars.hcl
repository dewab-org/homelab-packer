# Windows Server 2022 (Evaluation) ISO.
# NOTE: this ISO is not yet in the iso_images store. Download the Windows Server
# 2022 evaluation ISO from Microsoft, place it in iso_images, and set the exact
# filename below. Until then this build cannot run (config validates regardless).
iso_file = "iso_images:iso/windows-server-2022-eval-x64FRE-en-us.iso"
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
