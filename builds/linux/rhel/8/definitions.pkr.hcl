variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://proxmox.example.com:8006/api2/json"
  default     = env("PROXMOX_URL")
}

variable "proxmox_user" {
  type        = string
  description = "Proxmox API user, e.g. root@pam"
  default     = env("PROXMOX_USERNAME")
}

variable "proxmox_password" {
  type        = string
  description = "Proxmox API password"
  default     = env("PROXMOX_PASSWORD")
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name"
  default     = env("PROXMOX_NODE")
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool name"
  default     = env("PROXMOX_STORAGE")
}

variable "iso_storage_pool" {
  type        = string
  description = "Proxmox ISO storage pool name"
  default     = env("PROXMOX_ISO_STORAGE")
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

variable "iso_file" {
  type        = string
  description = "Proxmox ISO file path, e.g. iso_images:iso/rhel-10.1-x86_64-devd.iso"
}

variable "build_username" {
  type        = string
  description = "Build user for SSH connectivity"
  default     = env("BUILD_USERNAME")
}

variable "build_password" {
  type        = string
  description = "Build user password used during install"
  sensitive   = true
  default     = env("BUILD_PASSWORD")
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the private key matching the root sshkey in kickstart"
  default     = "~/.ssh/id_ed25519"
}

variable "root_password" {
  type        = string
  description = "Root password used during install"
  sensitive   = true
  default     = env("ROOT_PASSWORD")
}


variable "ks_language" {
  type        = string
  description = "Kickstart language"
  default     = env("KICKSTART_LANG")
}

variable "ks_keyboard" {
  type        = string
  description = "Kickstart keyboard"
  default     = env("KICKSTART_KEYBOARD")
}

variable "ks_timezone" {
  type        = string
  description = "Kickstart timezone"
  default     = env("KICKSTART_TIMEZONE")
}

variable "ssh_public_key_root" {
  type        = string
  description = "Root SSH public key"
  default     = env("SSH_PUBLIC_KEY_ROOT")
}

variable "ssh_public_key_build" {
  type        = string
  description = "Build user SSH public key"
  default     = env("SSH_PUBLIC_KEY_BUILD")
}
