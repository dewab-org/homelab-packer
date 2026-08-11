# Windows Server 2022 (Evaluation) ISO — build 20348, SERVER_EVAL x64 en-us.
# Same single-ISO/both-editions arrangement as 2025: windows_image_index below
# selects Core (1) vs Desktop Experience (2). Mirrored in the lab at:
# iso_url = "https://web.viking.org/cdimages/Microsoft/20348.169.210806-2348.fe_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
iso_file = "iso_images:iso/20348.169.210806-2348.fe_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
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
