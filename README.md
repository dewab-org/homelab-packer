# homelab.packer

Packer templates for building Proxmox VM templates across Linux families, plus Windows stubs.

## Layout

- `builds/linux/rhel/{8,9,10}`: RHEL builds with Satellite registration and Cloud-Init.
- `builds/linux/rocky/{8,9,10}`: Rocky Linux builds with Cloud-Init.
- `builds/linux/ubuntu/24.04`: Ubuntu 24.04 autoinstall build.
- `builds/windows/windows-10`: Windows 10 stub.
- `builds/windows/windows-server-2022`: Windows Server 2022 stub.
- `ca/`: Custom CA certificates applied by Linux configure playbooks.
- `build.sh`: Build one or all templates.

## Usage

1. Set shared values in `variables.auto.pkrvars.hcl` (language, keyboard, timezone, SSH keys, passwords).
2. Set per-release values in `builds/linux/*/*/variables.auto.pkrvars.hcl` (ISO path/URL, checksum, vm_id).
3. Build a template, for example:

```sh
./build.sh builds/linux/rhel/10
```

## Notes

- Each RHEL release registers to Satellite using credentials from `secrets.yml`.
- Use `./build.sh --ask` to keep the VM around on failure; `./build.sh --overwrite` to replace existing VMIDs.
- Use `./build.sh --skip` to skip builds when a matching template (or VMID) already exists in Proxmox.
- VMID mapping:
  - RHEL 8/9/10: 9108/9109/9110
  - Rocky 8/9/10: 9208/9209/9210
  - Ubuntu 24.04: 9301
- RHEL ISO storage pool: `iso_images` with the following filenames:
  - `rhel-8.10-x86_64-dvd.iso`
  - `rhel-9.7-x86_64-dvd.iso`
  - `rhel-10.1-x86_64-dvd.iso`
- All Linux builds enable Cloud-Init and the QEMU guest agent.
- `iso_file` (Proxmox storage reference) takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
- Rocky and Ubuntu can download official ISOs into Packer cache (`**/packer_cache`, ignored by git) or use `iso_file`.
- RHEL configure playbooks read Satellite credentials from `secrets.yml` (ignored by git).
