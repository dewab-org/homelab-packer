# Windows Server 2025 (Evaluation) ISO.
# Use iso_url (downloaded/cached by Packer) unless you explicitly set iso_file.
# iso_url = "https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
iso_file     = "iso_images:iso/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
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
vm_id = 9402

# Pin Desktop Experience explicitly. On the current Server 2025 eval ISO,
# index 2 is Standard Desktop Experience while index 1 is Standard Core.
windows_image_index = 2
