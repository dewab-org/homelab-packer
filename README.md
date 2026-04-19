# homelab.packer

Packer templates for building Proxmox VM templates across Linux families, plus Windows stubs.

## Layout

- `builds/linux/rhel/{8,9,10}`: RHEL builds with Satellite registration and Cloud-Init.
- `builds/linux/rocky/{8,9,10}`: Rocky Linux builds with Cloud-Init.
- `builds/linux/ubuntu/24.04`: Ubuntu 24.04 autoinstall build.
- `builds/windows/windows-10`: Windows 10 stub.
- `builds/windows/windows-server-2022`: Windows Server 2022 stub.
- `ca/`: Custom CA certificates applied by Linux configure playbooks.
- `build.py`: Build one or all templates.

## Usage

1. Set shared values in `variables.auto.pkrvars.hcl` (language, keyboard, timezone, SSH keys).
2. Set per-release values in `builds/linux/*/*/variables.auto.pkrvars.hcl` (ISO path/URL, checksum, vm_id).
3. Ensure `VAULT_ADDR`, `VAULT_TOKEN`, and `VAULT_CACERT` are set before running Packer. On the KV v2 `secret/` mount, Packer's native `vault()` function reads build secrets from `secret/data/packer`, and the Ansible lookup inherits the same Vault environment from the `packer build` process.
4. Build a template, for example:

```sh
./build.py builds/linux/rhel/10
```

## Notes

- Each RHEL release registers against Red Hat Network (RHN) using credentials from Vault (`secret/data/packer` in Packer, `secret/packer` via Vault CLI).
- Linux templates rely on Packer's built-in `vault()` function; there is no separate Packer Vault plugin to declare in `required_plugins`.
- Use `./build.py --ask` to keep the VM around on failure; `./build.py --overwrite` to replace existing VMIDs.
- Use `./build.py --skip` to skip builds when a matching template (or VMID) already exists in Proxmox.
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
