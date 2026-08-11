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

variable "iso_url" {
  type        = string
  description = "ISO URL (downloaded and cached by Packer)"
  default     = null
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum or checksum file URL"
  default     = null
}

variable "iso_file" {
  type        = string
  description = "ISO file reference in Proxmox storage (takes precedence over iso_url)"
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

variable "windows_image_index" {
  type        = number
  description = "Index in install.wim to install (edition selection)"
  default     = 1
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
