# Windows Server 2025 Desktop Experience

Windows Server 2025 Desktop Experience template build for Proxmox using `Autounattend.xml` and WinRM provisioning.

Required outcomes:
- Unattend-based install (in place)
- QEMU/virtio drivers injected (TODO)
- Cloudbase-Init (or equivalent) prepared for Proxmox "cloud-init style" configuration (TODO)

Notes:
- ISO handling follows the repo convention: `iso_file` (Proxmox storage reference) takes precedence; otherwise `iso_url` and `iso_checksum`.
- The local ISO file in `iso/` is a convenience; Packer still needs the ISO available to Proxmox as `iso_file`.
