# Ubuntu 24.04 Cloud Image

Ubuntu 24.04 template built from Canonical's released Noble cloud image instead of the live-server ISO installer.

Required outcomes:
- Uses a local Proxmox base template imported from the official Ubuntu Noble cloud image
- Cloud-Init enabled with a Proxmox cloud-init drive
- QEMU guest agent installed and enabled in the guest image
- Serial console enabled for runtime access
- Template cleanup before import

Notes:
- `scripts/bootstrap-base-template.py` creates or updates the base template from Canonical's cloud image. By default it uses VMID `9310` and template name `ubuntu-24-04-cloud-base`.
- The bootstrap script downloads the upstream image through the Proxmox `download-url` API into an import-capable storage. Existing cached import volumes are reused unless `--refresh-image` is passed.
- Packer then uses `proxmox-clone` against the base template to generate VMID `9311` with template name `ubuntu-24-04-cloud`.
- The cloned template disk is resized to `60G` by a Proxmox API finalizer after template conversion. If the backing storage is `local-lvm`, the resulting virtual disk is LVM-thin-backed on the host.
- Template customization reuses `../24.04/ansible/configure.yml`, the same Ansible playbook used by the Ubuntu ISO/autoinstall build.
- A Packer-generated NoCloud seed is attached only during the build to install/start `qemu-guest-agent` and inject the build SSH key before Packer discovers the DHCP address.
- A post-conversion API finalizer keeps the template's Proxmox cloud-init network config set to DHCP (`ipconfig0=ip=dhcp`).
- `./build.py --overwrite builds/linux/ubuntu/24.04-cloud` replaces an existing VM or template with VMID `9311`.
- The import storage must have the `import` content type enabled. Set `PROXMOX_IMPORT_STORAGE` if it is not `PROXMOX_ISO_STORAGE` or `local`.

Bootstrap the base template:

```sh
set -a
source .env
set +a
OVERWRITE_EXISTING=true builds/linux/ubuntu/24.04-cloud/scripts/bootstrap-base-template.py
```

Build the final Packer template:

```sh
./build.py --overwrite builds/linux/ubuntu/24.04-cloud
```
