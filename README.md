# homelab.packer

[![build-templates](https://github.com/dewab/homelab-packer/actions/workflows/build-templates.yml/badge.svg)](https://github.com/dewab/homelab-packer/actions/workflows/build-templates.yml)
[![validate-templates](https://github.com/dewab/homelab-packer/actions/workflows/validate-templates.yml/badge.svg)](https://github.com/dewab/homelab-packer/actions/workflows/validate-templates.yml)
[![verify-templates](https://github.com/dewab/homelab-packer/actions/workflows/verify-templates.yml/badge.svg)](https://github.com/dewab/homelab-packer/actions/workflows/verify-templates.yml)
[![gitleaks](https://github.com/dewab/homelab-packer/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/dewab/homelab-packer/actions/workflows/gitleaks.yml)

Packer templates for building Proxmox VM templates across Linux families, plus in-progress Windows templates.

## Layout

- `builds/linux/rhel/{8,9,10}`: RHEL ISO/kickstart builds with RHN registration and Cloud-Init.
- `builds/linux/rhel/{8,9,10}-cloud`: RHEL cloud-image (qcow2) builds cloned from bootstrapped base templates.
- `builds/linux/rocky/{8,9,10}`: Rocky Linux ISO/kickstart builds with Cloud-Init.
- `builds/linux/rocky/{8,9,10}-cloud`: Rocky cloud-image (GenericCloud qcow2) builds.
- `builds/linux/ubuntu/24.04`: Ubuntu 24.04 autoinstall build.
- `builds/linux/ubuntu/24.04-cloud`: Ubuntu 24.04 cloud-image build.
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

## Build targets — cloud-image first

`build.py` accepts a build directory or one of four keywords:

| Target | Builds | |
| --- | --- | --- |
| `all` | the 7 `-cloud` builds | **default** |
| `cloud` | same as `all` | explicit spelling |
| `iso` | the 7 ISO/kickstart builds | opt-in |
| `all-linux` | all 14 Linux builds | the pre-2026-08 `all` |

```sh
./build.py all          # cloud images (fast path)
./build.py iso          # ISO/kickstart builds, explicitly
./build.py builds/linux/rocky/9-cloud
```

**`all` means cloud-only on purpose.** Cloud builds clone a vendor qcow2 and
take minutes; ISO builds drive an installer through a boot command and are far
slower and more fragile — GRUB keystroke timing has broken them more than once.
Both flavours run the same `builds/linux/ansible/` playbooks, so they install
the same packages, CA certificates, and customisations; the resulting templates
differ in how the base OS was laid down, not in what is on them.

Reach for `iso` when a vendor cloud image genuinely will not do: a from-scratch
partition layout, an install-time option such as FIPS or a STIG profile, or an
OS with no published cloud image.

CI follows the same rule. The weekly Sunday rebuild and any push-triggered
build run the default (cloud-only); ISO templates are rebuilt on demand via
`workflow_dispatch` with `build_target=iso`. Pushes that touch *only* an ISO
build directory do not trigger CI at all, since the default target would not
rebuild the thing that changed.

## Clone verification

A template that builds cleanly can still be unusable — Linux cloud-init that
never re-arms silently skips user/password/hostname on a clone, and a Windows
template can ship with no cloud-init drive. `tests/clone-verify.py` catches
that: for each template it linked-clones it, attaches a cloud-init payload,
boots it, and proves the guest was actually configured, then destroys the
clone (always, even on failure).

Checks per clone:

- a login user was created from the cloud-init data
- remote access works — SSH with the injected key (Linux), or a validated
  credential (Windows)
- the hostname became the clone's name (a template that did not re-arm keeps
  the build hostname)
- the homelab CA is present in the trust store

```sh
set -a && source .env && set +a
export PROXMOX_URL=... PROXMOX_USERNAME=... PROXMOX_PASSWORD=... PROXMOX_NODE=...
./tests/clone-verify.py 9239 9432          # rocky-9 + win-2022, or any VMIDs
```

CI runs it via the `verify-templates` workflow after every successful
`build-templates` run, and on demand (`workflow_dispatch`). It clones live VMs,
so it deliberately does not run on push and never runs concurrently with a
build (shared concurrency group + the 9600+ clone VMID range).

## Notes

- Each RHEL release registers against Red Hat Network (RHN) using credentials from Vault (`secret/data/packer` in Packer, `secret/packer` via Vault CLI).
- Linux templates rely on Packer's built-in `vault()` function; there is no separate Packer Vault plugin to declare in `required_plugins`.
- Each build run now generates an ephemeral SSH keypair for the build user. The persistent root authorized key still comes from Vault.
- Use `./build.py --ask` to keep the VM around on failure; `./build.py --overwrite` to replace existing VMIDs.
- Use `./build.py --skip` to skip builds when a matching template (or VMID) already exists in Proxmox.
- Use `./build.py --init-only` to run `packer init` only.
- Use `./build.py --validate-only` to run `packer init` and `packer validate` without starting a Proxmox build.
- VMID mapping (cloud-base = ISO VMID +20, cloud template = ISO VMID +30):
  - RHEL 8/9/10 ISO: 9108/9109/9110; cloud-base: 9128/9129/9130; cloud: 9138/9139/9140
  - Rocky 8/9/10 ISO: 9208/9209/9210; cloud-base: 9228/9229/9230; cloud: 9238/9239/9240
  - Ubuntu 24.04 ISO/autoinstall: 9301; cloud-base: 9310; cloud: 9311

### Windows VMID map

The `+20/+30` arithmetic does not extend cleanly to Windows (Ubuntu already
breaks it too), so the Windows allocation is an explicit table:

| Build | ISO | cloud-base | cloud |
| --- | --- | --- | --- |
| Server 2022 Core | *(ISO-only, see below)* | 9421 | 9431 |
| Server 2022 Desktop Experience | — | 9422 | 9432 |
| Server 2025 Core | 9401 | 9423 | 9433 |
| Server 2025 Desktop Experience | 9403 | 9424 | 9434 |

`9402` is intentionally free. An early Server 2025 desktop-experience build
landed there on 2026-03-12 and was superseded by a rebuild at `9403` on
2026-03-14 which took the canonical name; the repo now tracks the live
template rather than renumbering a working one. `9401` was likewise carrying a
misleading `-base` suffix in Proxmox — it is an ISO build, not a cloud base —
and has been renamed to match this table.

### Windows cloud images

Built by cloning a base template imported from a Microsoft evaluation VHD/VHDX,
which skips Windows Setup entirely (no `boot_command`, no keystroke timing).

| Template | Firmware | Disk |
| --- | --- | --- |
| `9432 windows-server-2022-desktop-experience-cloud` | SeaBIOS (MBR) | 40 G |
| `9434 windows-server-2025-desktop-experience-cloud` | OVMF (GPT) | 64 G |

**The base templates (9422/9424) are not kept.** Each is ~10 G of a 338 G thin
pool and exists only so Packer can clone without re-importing. Recreate one
before building:

```sh
set -a && source .env && set +a
builds/windows/common/scripts/reimport-windows-base.sh both   # or 2022 / 2025
./build.py builds/windows/windows-server-2022-desktop-experience-cloud
```

That wrapper renders the answer file from `autounattend-vhd.pkrtpl.xml` with the
Vault build credentials and injects it offline into
`\Windows\Panther\unattend.xml`. Do not skip it and hand-copy an old
`unattend.xml`: OOBE reads answer files only from fixed on-disk locations (the
removable-media search is a Windows *Setup* behaviour), and a stale one leaves
the guest sitting at OOBE with no obvious error.

Known gaps, both deliberate:

- **`switch_to_virtio` is off.** Templates ship on SATA/e1000. Moving the boot
  disk to virtio-scsi yields clones that boot into the Recovery Environment —
  having viostor/vioscsi in the driver store does not make the controller
  boot-critical. A fix needs a scratch virtio-scsi disk attached during the
  build so Windows enumerates the controller first.
- **Cloudbase-Init is not installed.** `cloudbase.it` is unreachable from this
  lab, so a clone will not consume its cloud-init drive. Mirror the MSI to
  `web.viking.org/cdimages/Microsoft/` and uncomment `cloudbase_init_url` in the
  cloud vars files to close this.

**Edition selection differs between the two paths.** An ISO carries several
editions in `install.wim` and the build picks one with `windows_image_index`
(`1` = Core, `2` = Desktop Experience). A VHD/VHDX contains a *single already
installed* edition, so there is no index to choose: one image yields one
flavour. Microsoft publishes eval VHDs for Desktop Experience but not for
Core, so a Core template generally still has to come from the ISO path.

- RHEL ISO storage pool: `iso_images` with the following filenames:
  - `rhel-8.10-x86_64-dvd.iso`
  - `rhel-9.8-x86_64-dvd.iso`
  - `rhel-10.2-x86_64-dvd.iso`
  (RHEL ISOs and qcow2 images are mirrored at <https://web.viking.org/cdimages/Linux/RedHat/>, backed by nas.viking.org:/mnt/pool0/cdimages)
- All Linux builds enable Cloud-Init and the QEMU guest agent.
- All RHEL and Rocky kickstarts install `cloud-init` during the installer phase; Ansible only verifies and enables it.
- `iso_file` (Proxmox storage reference) takes precedence when set; otherwise `iso_url` downloads and `iso_checksum` validates when provided.
- Rocky and Ubuntu ISO builds can download official ISOs into Packer cache (`**/packer_cache`, ignored by git) or use `iso_file`.
- The Ubuntu cloud-image flow bootstraps a base template from Canonical's released Noble cloud image using Proxmox API import storage caching, then uses Packer `proxmox-clone` to template VMID 9311.
- The cloud builds install the same packages and apply the same customizations as the kickstart builds (base package set, root/build users with identical passwords and authorized keys, sshd `90-packer.conf`, authselect sssd, timezone, enabled services, CA trust, identity cleanup). The one inherent difference: cloud images keep their single-partition root filesystem instead of the kickstart thin-LVM layout with separate `/var`, `/home`, and swap.
- The RHEL/Rocky cloud-image flow works the same way: `builds/linux/common/scripts/bootstrap-cloud-bases.py` creates all six base templates from the pinned images in `builds/linux/common/cloud-base-images.json`; each `*-cloud` build directory symlinks the shared `builds/linux/common/cloud-clone-build.pkr.hcl`. RHEL cloud images register to RHN at cloud-init time (rh_subscription) so qemu-guest-agent can be installed, and are unregistered by the shared `builds/linux/ansible/cloud_configure.yml` before templating.
- The cloud-image template disk is resized to 60G via a Proxmox API finalizer after cloning.
- CI now has two paths:
  - `build-templates`: full Proxmox build workflow, with manual `build_target` selection
  - `validate-templates`: static validation workflow, with manual `validate_target` selection
