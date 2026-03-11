# AGENTS

- Project: Packer templates for Proxmox VM templates (Linux families and Windows stubs).
- Entry points: `builds/linux/rhel/10/build.pkr.hcl` and sibling release directories.
- Conventions: Keep files ASCII; prefer explicit variables over hard-coded values.
- Usage: `./build.sh builds/linux/rhel/10` (add `--ask`, `--overwrite`, or `--skip` as needed).
- Use a single top-level `ca` directory for all CA certs.
- All Linux distros should install python3 as part of the base image (not as a separate provisioner step).
- Windows templates should use `autounattend.xml` for unattended installation.
- All Linux distros should configure a serial console during installation and for usage after install.
- ISO handling: `iso_file` (Proxmox storage reference) takes precedence; otherwise use `iso_url` and `iso_checksum` when defined.
- Ansible playbooks are named `ansible/configure.yml` under each build directory.
- Shared build variables live in `variables.auto.pkrvars.hcl` at repo root.
- RHEL builds read Satellite credentials from `secrets.yml` (ignored by git).
- RHEL/Rocky 8 uses Python 3.8; keep ansible-core at 2.15 for compatibility.
