# homelab.packer

Packer templates for building Proxmox VM templates across Linux families, plus in-progress Windows templates.

## Layout

- `builds/linux/rhel/{8,9,10}`: RHEL builds with Satellite registration and Cloud-Init.
- `builds/linux/rocky/{8,9,10}`: Rocky Linux builds with Cloud-Init.
- `builds/linux/ubuntu/24.04`: Ubuntu 24.04 autoinstall build.
- `builds/windows/windows-10`: Windows 10 stub.
- `builds/windows/windows-server-2022`: Windows Server 2022 stub.
- `ca/`: Custom CA certificates applied by Linux configure playbooks.
- `build.py`: Init, validate, or build one or all templates.

## Usage

1. Set shared values in `variables.auto.pkrvars.hcl` (language, keyboard, timezone).
2. Set per-release values in `builds/linux/*/*/variables.auto.pkrvars.hcl` (ISO path/URL, checksum, vm_id).
3. Ensure `VAULT_ADDR`, `VAULT_TOKEN`, and `VAULT_CACERT` are set before running Packer. On the KV v2 `secret/` mount, Packer's native `vault()` function reads build secrets from `secret/data/packer`, and the Ansible lookup inherits the same Vault environment from the `packer build` process.
4. Initialize or validate a target before building, for example:

```sh
./build.py --init-only builds/linux/rhel/10
./build.py --validate-only builds/linux/rhel/10
```

1. Build a template, for example:

```sh
./build.py builds/linux/rhel/10
```

## Notes

- Each RHEL release registers against Red Hat Network (RHN) using credentials from Vault (`secret/data/packer` in Packer, `secret/packer` via Vault CLI).
- Linux templates rely on Packer's built-in `vault()` function; there is no separate Packer Vault plugin to declare in `required_plugins`.
- Each build run now generates an ephemeral SSH keypair for the build user. The persistent root authorized key still comes from Vault.
- Use `./build.py --ask` to keep the VM around on failure; `./build.py --overwrite` to replace existing VMIDs.
- Use `./build.py --skip` to skip builds when a matching template (or VMID) already exists in Proxmox.
- Use `./build.py --init-only` to run `packer init` only.
- Use `./build.py --validate-only` to run `packer init` and `packer validate` without starting a Proxmox build.
- VMID mapping:
  - RHEL 8/9/10: 9108/9109/9110
  - Rocky 8/9/10: 9208/9209/9210
  - Ubuntu 24.04: 9301
- RHEL ISO storage pool: `iso_images` with the following filenames:
  - `rhel-8.10-x86_64-dvd.iso`
  - `rhel-9.7-x86_64-dvd.iso`
  - `rhel-10.1-x86_64-dvd.iso`
- All Linux builds enable Cloud-Init and the QEMU guest agent.
- All RHEL and Rocky kickstarts install `cloud-init` during the installer phase; Ansible only verifies and enables it.
- `iso_file` (Proxmox storage reference) takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
- Rocky and Ubuntu can download official ISOs into Packer cache (`**/packer_cache`, ignored by git) or use `iso_file`.
- CI now has two paths:
  - `build-templates`: full Proxmox build workflow, with manual `build_target` selection
  - `validate-templates`: static validation workflow, with manual `validate_target` selection
