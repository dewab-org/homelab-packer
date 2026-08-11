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

vm_id = 9413

# Pin Desktop Experience explicitly: on the Server 2022 eval ISO, index 2 is
# Standard Desktop Experience while index 1 is Standard Core.
windows_image_index = 2
