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

# Leave the template on SATA/e1000. Switching the boot disk to virtio-scsi
# produces a template whose clones boot into the Windows Recovery Environment —
# the guest tools put viostor/vioscsi in the driver store, but that does not make
# the controller boot-critical. See switch_to_virtio in common/definitions.pkr.hcl.
switch_to_virtio = false

# Cloudbase-Init — the Windows counterpart to cloud-init. Without it the
# cloud-init drive Proxmox attaches is inert: nothing in the guest reads it.
#
# Sourced from the project's GitHub releases, NOT cloudbase.it. The vendor site
# times out from everywhere tested (guest, Proxmox host, workstation) while
# github.com answers in under a second, so the earlier "no egress" diagnosis
# was wrong — cloudbase.it is simply unreachable. The GitHub asset is the same
# official installer (verified: MSI metadata reads "Cloudbase-Init 1.1.8",
# publisher "Cloudbase Solutions Srl").
#
# Pinned with a checksum so a silently-changed artifact fails the build rather
# than shipping into a template.
cloudbase_init_url      = "https://github.com/cloudbase/cloudbase-init/releases/download/1.1.8/CloudbaseInitSetup_1_1_8_x64.msi"
cloudbase_init_checksum = "sha256:0e7fa42e0cbc0ce7657f85730b0c6cc7afc4087a3639df0ff51a721a0be19bd5"
