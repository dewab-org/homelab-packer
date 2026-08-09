variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://proxmox.example.com:8006/api2/json"
  default     = null
}

variable "proxmox_user" {
  type        = string
  description = "Proxmox API user, e.g. root@pam"
  default     = null
}

variable "proxmox_password" {
  type        = string
  description = "Proxmox API password"
  default     = null
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name"
  default     = null
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool name"
  default     = null
}

variable "iso_storage_pool" {
  type        = string
  description = "Proxmox ISO storage pool name"
  default     = null
}

variable "bridge" {
  type        = string
  description = "Proxmox bridge name"
  default     = "vmbr0"
}

variable "vm_id" {
  type        = number
  description = "Optional Proxmox VM ID"
  default     = null
}




variable "build_username" {
  type        = string
  description = "Build user for WinRM connectivity"
  default     = null
}

variable "build_password" {
  type        = string
  description = "Build user password used during install"
  sensitive   = true
  default     = null
}

variable "root_password" {
  type        = string
  description = "Unused for Windows builds (present in shared vars file)"
  sensitive   = true
  default     = null
}

variable "ssh_public_key_root" {
  type        = string
  description = "Unused for Windows builds (present in shared vars file)"
  default     = null
}

variable "ssh_public_key_build" {
  type        = string
  description = "Unused for Windows builds (present in shared vars file)"
  default     = null
}

variable "ssh_private_key_file" {
  type        = string
  description = "Unused for Windows builds (passed by build.py for Linux templates)"
  default     = null
}

variable "ks_language" {
  type        = string
  description = "Deprecated for Windows builds (kickstart/Linux naming). Use win_language instead."
  default     = env("KICKSTART_LANG")
}

variable "ks_keyboard" {
  type        = string
  description = "Deprecated for Windows builds (kickstart/Linux naming). Use win_keyboard instead."
  default     = env("KICKSTART_KEYBOARD")
}

variable "ks_timezone" {
  type        = string
  description = "Deprecated for Windows builds (kickstart/Linux naming). Use win_timezone instead."
  default     = env("KICKSTART_TIMEZONE")
}

variable "win_language" {
  type        = string
  description = "Windows UI/system locale, e.g. en-US"
  default     = env("WIN_LANGUAGE") != "" ? env("WIN_LANGUAGE") : "en-US"
}

variable "win_keyboard" {
  type        = string
  description = "Windows keyboard/input locale, e.g. en-US"
  default     = env("WIN_KEYBOARD") != "" ? env("WIN_KEYBOARD") : "en-US"
}

variable "win_timezone" {
  type        = string
  description = "Windows time zone ID, e.g. Central Standard Time"
  default     = env("WIN_TIMEZONE") != "" ? env("WIN_TIMEZONE") : "Central Standard Time"
}


variable "virtio_iso_file" {
  type        = string
  description = "VirtIO ISO file reference in Proxmox storage (preferred), e.g. iso_images:iso/virtio-win.iso"
  default     = env("VIRTIO_ISO_FILE") != "" ? env("VIRTIO_ISO_FILE") : "iso_images:iso/virtio-win.iso"
}

variable "virtio_iso_url" {
  type        = string
  description = "VirtIO ISO URL (used only when virtio_iso_file is not set)"
  default     = env("VIRTIO_ISO_URL") != "" ? env("VIRTIO_ISO_URL") : null
}

variable "virtio_iso_checksum" {
  type        = string
  description = "VirtIO ISO checksum (use 'none' to skip)"
  default     = env("VIRTIO_ISO_CHECKSUM") != "" ? env("VIRTIO_ISO_CHECKSUM") : "none"
}

variable "cloudbase_init_url" {
  type        = string
  description = "Optional Cloudbase-Init installer URL; when set, enable Proxmox cloud-init disk and install Cloudbase-Init"
  default     = env("CLOUDBASE_INIT_URL") != "" ? env("CLOUDBASE_INIT_URL") : null
}

variable "cloudbase_init_checksum" {
  type        = string
  description = "Checksum for the Cloudbase-Init installer URL (use 'none' to skip)"
  default     = env("CLOUDBASE_INIT_CHECKSUM") != "" ? env("CLOUDBASE_INIT_CHECKSUM") : "none"
}

// --- clone-specific ------------------------------------------------------
variable "clone_vm_id" {
  type        = number
  description = "VMID of the cloud-base template to clone (created from the vendor VHD/VHDX)"
}

variable "template_name" {
  type        = string
  description = "Name of the resulting template"
}

variable "template_description_prefix" {
  type    = string
  default = "Windows cloud-image template"
}

// Post-build bus switch, DEFAULT OFF.
//
// The vendor VHD boots SATA/e1000 because it carries no virtio drivers, and the
// intent was to flip the finished template to virtio-scsi/virtio-net once
// 03-install-virtio-guest-tools.ps1 had installed them. That does not work as
// implemented: a clone of the switched template boots into the Windows Recovery
// Environment. Installing the guest tools puts viostor/vioscsi in the driver
// store, but that alone does not make the storage controller boot-critical, so
// Windows cannot find its system disk on the new bus.
//
// Making it work needs the controller present at boot before the switch — e.g.
// attach a scratch virtio-scsi disk during the build so Windows enumerates the
// controller and activates the driver, then move the system disk. Until that is
// implemented and verified, templates ship on SATA/e1000, which is perfectly
// adequate for the test VMs these are for.
//
// The NIC half is harmless on its own (virtio-net is not boot-critical), but the
// switch is all-or-nothing today, so it stays off.
variable "switch_to_virtio" {
  type    = bool
  default = false
}

// Proxmox task timeout for the clone. Default 1m is too short for Windows-sized
// disks; see the comment in cloud-clone-build.pkr.hcl.
variable "clone_task_timeout" {
  type    = string
  default = "20m"
}

// Proxmox ostype for the finished template. win10 covers 2016/2019/2022;
// win11 is correct for 2025. Packer leaves it as "other", which suppresses the
// configdrive2 citype default that Cloudbase-Init depends on.
variable "windows_ostype" {
  type    = string
  default = "win10"
}
