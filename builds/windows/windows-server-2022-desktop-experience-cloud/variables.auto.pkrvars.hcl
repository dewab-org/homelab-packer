# Windows Server 2022 Desktop Experience, cloned from the vendor evaluation image.
#
# The base template (clone_vm_id) is imported once from Microsoft's evaluation
# VHD/VHDX — see the repo README, "Windows cloud images". Cloning it skips
# Windows Setup, so there is no boot_command and no windows_image_index: the
# image already contains exactly one installed edition (Desktop Experience;
# Microsoft publishes no Core VHD, so Core stays on the ISO path).
clone_vm_id   = 9422
vm_id         = 9432
template_name = "windows-server-2022-desktop-experience-cloud"

template_description_prefix = "Windows Server 2022 Desktop Experience cloud image template"

# VirtIO drivers + guest tools, installed in-guest. Left attached during the
# build; there is no WinPE phase in which to inject them.
virtio_iso_file = "iso_images:iso/virtio-win-0.1.285.iso"

bridge = "vmbr0"

win_language = "en-US"
win_keyboard = "en-US"
win_timezone = "Central Standard Time"

# Move the finished template onto virtio-scsi/virtio-net once the guest tools
# have installed the drivers. Set false to leave it on SATA/e1000.
switch_to_virtio = true

# Cloudbase-Init — the Windows counterpart to cloud-init, and what makes a clone
# customisable at first boot from the Proxmox cloud-init drive.
#
# DELIBERATELY UNSET. cloudbase.it is not reachable from this lab (verified:
# both the build guest and the Proxmox host itself get "Unable to connect to
# the remote server" / HTTP 000), so pointing at the upstream URL fails the
# build outright. With it unset, 60-install-cloudbase-init.ps1 logs
# "Cloudbase-Init URL not set. Skipping" and continues.
#
# BE AWARE: that means the template ships WITHOUT Cloudbase-Init and a clone
# will not consume its cloud-init drive. To close the gap, mirror the MSI
# alongside the other images and point this at the internal copy:
#
#   https://web.viking.org/cdimages/Microsoft/CloudbaseInitSetup_Stable_x64.msi
#
# then set cloudbase_init_url (and ideally a sha256 checksum) here.
# cloudbase_init_url      = "https://web.viking.org/cdimages/Microsoft/CloudbaseInitSetup_Stable_x64.msi"
# cloudbase_init_checksum = "sha256:<fill in>"
