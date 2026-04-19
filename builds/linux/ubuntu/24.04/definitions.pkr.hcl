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
  sensitive   = true
  default     = null
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
  description = "Build user for SSH connectivity"
  default     = null
}

variable "build_password" {
  type        = string
  description = "Build user password used during install"
  sensitive   = true
  default     = null
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the private key used by the build account during provisioning"
  default     = "~/.ssh/id_ed25519"
}

variable "root_password" {
  type        = string
  description = "Root password used during install"
  sensitive   = true
  default     = null
}

variable "ks_language" {
  type        = string
  description = "Installer language"
  default     = env("KICKSTART_LANG")
}

variable "ks_keyboard" {
  type        = string
  description = "Installer keyboard"
  default     = env("KICKSTART_KEYBOARD")
}

variable "ks_timezone" {
  type        = string
  description = "Installer timezone"
  default     = env("KICKSTART_TIMEZONE")
}

variable "ssh_public_key_root_authorized" {
  type        = string
  description = "Persistent SSH public key to add to root authorized_keys"
  default     = null
}

variable "ssh_public_key_build" {
  type        = string
  description = "Optional override for the build user's SSH public key; defaults to ssh_private_key_file.pub"
  default     = null
}
