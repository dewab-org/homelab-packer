packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
  serials = ["socket"]
}

# TODO: add unattend, virtio drivers, and build blocks for Windows Server 2022.
