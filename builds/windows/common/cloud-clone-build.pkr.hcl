// Shared proxmox-clone build for Windows cloud-image templates.
//
// Each builds/windows/<name>-cloud/ directory symlinks this file as
// build.pkr.hcl and supplies clone_vm_id / vm_id / template_name in its
// variables.auto.pkrvars.hcl — the same arrangement as
// builds/linux/common/cloud-clone-build.pkr.hcl.
//
// The base template (clone_vm_id) is imported once from a Microsoft evaluation
// VHD/VHDX; see the README "Windows cloud images" section for the bootstrap.
// Cloning it skips Windows Setup entirely, which removes the slowest and by far
// the most fragile part of the ISO builds (boot_command keystroke timing).
//
// What a vendor VHD does NOT give you, unlike a Linux cloud image:
//
//   * No cloud-init equivalent preinstalled, so the image boots to an
//     interactive OOBE and waits. The answer file is injected OFFLINE into the
//     base at \Windows\Panther\unattend.xml by
//     common/scripts/bootstrap-windows-base.sh — it is NOT delivered on the CD.
//     Scanning removable media for Autounattend.xml is Windows *Setup*
//     behaviour; an already-installed image resumes at the OOBE pass, which
//     reads a fixed set of on-disk locations instead. The CD below still
//     matters: the injected unattend runs bootstrap.cmd from it.
//
//   * No QEMU guest agent. Packer discovers the VM's IP by asking the agent, so
//     without one the build waits on WinRM forever while the guest sits happily
//     on a DHCP lease. 00-install-qemu-ga.ps1 installs it during bootstrap,
//     before WinRM is needed.
//
//   * No virtio drivers. The base therefore boots SATA + e1000; virtio is
//     installed in-guest by 10-install-virtio-guest-tools.ps1, after which the
//     bus is switched by the post-processor (see switch_to_virtio).

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
    windows-update = {
      version = ">= 0.18.0"
      source  = "github.com/rgl/windows-update"
    }
  }
}

locals {
  proxmox_url      = var.proxmox_url != null ? var.proxmox_url : vault("secret/data/packer", "PROXMOX_URL")
  proxmox_user     = var.proxmox_user != null ? var.proxmox_user : vault("secret/data/packer", "PROXMOX_USERNAME")
  proxmox_password = var.proxmox_password != null ? var.proxmox_password : vault("secret/data/packer", "PROXMOX_PASSWORD")
  proxmox_node     = var.proxmox_node != null ? var.proxmox_node : vault("secret/data/packer", "PROXMOX_NODE")

  # API TOKEN, not username+password. A password login mints a ticket that
  # expires after 2 HOURS, and a Windows build takes 2h02m - so the session
  # died exactly at teardown/template-conversion, the most expensive possible
  # moment. It surfaced as "401 Authentication failed!" while Packer tried to
  # stop and delete the VM, which then STRANDED the VM and its disk. API tokens
  # do not expire, so the last minutes of a long build are no longer a race.
  proxmox_token_id            = vault("secret/data/packer", "PROXMOX_TOKEN_ID")
  proxmox_token_secret        = vault("secret/data/packer", "PROXMOX_TOKEN_SECRET")
  storage_pool                = var.storage_pool != null ? var.storage_pool : vault("secret/data/packer", "PROXMOX_STORAGE")
  iso_storage_pool            = var.iso_storage_pool != null ? var.iso_storage_pool : vault("secret/data/packer", "PROXMOX_ISO_STORAGE")
  build_username              = var.build_username != null ? var.build_username : vault("secret/data/packer", "BUILD_USERNAME")
  build_password              = var.build_password != null ? var.build_password : vault("secret/data/packer", "BUILD_PASSWORD")
  cd_label                    = "PACKER"
  cloudbase_init_url_env      = var.cloudbase_init_url != null ? var.cloudbase_init_url : ""
  cloudbase_init_checksum_env = var.cloudbase_init_checksum != null ? var.cloudbase_init_checksum : ""

  // Rendered for reference and for common/scripts/bootstrap-windows-base.sh,
  // which injects it into the base image offline. Not shipped on the CD:
  // OOBE does not read answer files from removable media.
  autounattend_xml = templatefile("${path.root}/../common/files/autounattend-vhd.pkrtpl.xml", {
    win_language   = var.win_language
    win_keyboard   = var.win_keyboard
    win_timezone   = var.win_timezone
    build_username = local.build_username
    build_password = local.build_password
  })
}

source "proxmox-clone" "windows_cloud" {
  proxmox_url              = local.proxmox_url
  username                 = local.proxmox_token_id
  token                    = local.proxmox_token_secret
  node                     = local.proxmox_node
  insecure_skip_tls_verify = true

  clone_vm_id = var.clone_vm_id
  full_clone  = true

  // The plugin's default task_timeout is 1 minute, which is fine for the Linux
  // cloud clones (9-13s observed) but not for Windows: the 2022 base is 40G and
  // took 70s, so the very first run failed with "Wait timeout for ... qmclone"
  // *after the clone had actually succeeded*, leaving an orphaned VM behind.
  // 2025 is 64G and slower still.
  task_timeout = var.clone_task_timeout

  vm_id                = var.vm_id
  vm_name              = "${var.template_name}-build"
  template_name        = var.template_name
  template_description = "${var.template_description_prefix} generated by Packer on ${formatdate("YYYY-MM-DD hh:mm:ss", timestamp())} UTC"
  onboot               = true

  cpu_type = "host"
  sockets  = 1
  cores    = 4
  memory   = 8192

  qemu_agent = true

  # Serial device so every template carries VGA (default) + a serial console.
  serials = ["socket"]

  // NOTE: cloud_init is NOT set here. proxmox-clone drops the base's inherited
  // cloud-init CD on clone, and setting cloud_init=true here conflicted with
  // that inherited drive and produced a template with no ide2 at all. The
  // finalize post-processor (switch-template-to-virtio.py) adds and verifies
  // the drive instead, so there is a single owner of it.

  // Disks, firmware and NIC are inherited from the base template. They are not
  // redeclared here: proxmox-clone takes the source VM's hardware, and the base
  // deliberately differs per release (2022 is MBR/SeaBIOS, 2025 is GPT/OVMF).

  // Bootstrap payload only. The answer file is NOT here — it lives in the base
  // image at \Windows\Panther\unattend.xml (see the header); the injected
  // unattend invokes bootstrap.cmd from this CD at first logon.
  additional_iso_files {
    cd_content = {
      "/bootstrap.cmd"                             = file("${path.root}/../common/files/bootstrap.cmd")
      "/bootstrap.ps1"                             = file("${path.root}/../common/files/bootstrap-vhd.ps1")
      "/scripts/00-install-qemu-ga.ps1"            = file("${path.root}/../common/scripts/00-install-qemu-ga.ps1")
      "/scripts/10-install-virtio-guest-tools.ps1" = file("${path.root}/../common/scripts/10-install-virtio-guest-tools.ps1")
      "/scripts/01-enable-winrm.ps1"               = file("${path.root}/../common/scripts/01-enable-winrm.ps1")
      "/root_ca_bundle.pem"                        = file("${path.root}/../common/files/root_ca_bundle.pem")
    }
    cd_label         = local.cd_label
    iso_storage_pool = local.iso_storage_pool
    type             = "ide"
    index            = "3"
    unmount          = true
  }

  // VirtIO drivers + guest tools, installed in-guest (no WinPE phase to inject
  // them into). Left mounted so 10-install-virtio-guest-tools.ps1 can find it.
  additional_iso_files {
    iso_file = var.virtio_iso_file
    type     = "sata"
    index    = "1"
    unmount  = false
  }

  communicator   = "winrm"
  winrm_username = local.build_username
  winrm_password = local.build_password
  winrm_port     = 5985
  winrm_timeout  = "90m"
  winrm_use_ssl  = false
}

build {
  sources = ["source.proxmox-clone.windows_cloud"]
  # FIRST, before anything else - including Windows Update. The bootstrap
  # scripts exit 0 by design (a non-zero exit from a first-logon command aborts
  # the logon sequence) and record their verdict in marker files; this reads
  # them. It has to run before the update pass or a broken bootstrap is only
  # discovered ~35 minutes later, which defeats the point of failing fast.
  provisioner "powershell" {
    scripts = [
      "${path.root}/../common/scripts/04-assert-bootstrap-clean.ps1",
    ]
  }


  # Fully patch the image FIRST so weekly builds ship current and the rest of
  # the config lands on a patched OS. The rgl plugin drives the Windows Update
  # Agent and reboots as needed until no updates remain — this can add
  # significant time off an old base, which is the point. Cleanup (998-cleanup)
  # stays last, after this and the config below.
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
  }

  provisioner "powershell" {
    inline = ["New-Item -Path 'C:\\Install' -ItemType Directory -Force | Out-Null"]
  }

  provisioner "powershell" {
    // Run via a scheduled task as the build user rather than straight over
    // WinRM. DISM-backed operations (Add-WindowsCapability for OpenSSH, and
    // some of the feature installs below) fail with "Access is denied" in a
    // plain WinRM session because it does not carry a fully elevated token.
    elevated_user     = local.build_username
    elevated_password = local.build_password

    environment_vars = [
      "CLOUDBASE_INIT_URL=${local.cloudbase_init_url_env}",
      "CLOUDBASE_INIT_CHECKSUM=${local.cloudbase_init_checksum_env}",
    ]
    scripts = [
      // 10-install-virtio-guest-tools runs in bootstrap (pre-WinRM), not here:
      // the guest agent needs its virtio-serial driver before Packer can find
      // the VM at all. By this point the drivers are already installed.
      "${path.root}/../common/scripts/11-install-lab-ca.ps1",
      "${path.root}/../common/scripts/20-enable-rdp.ps1",
      "${path.root}/../common/scripts/21-enable-openssh.ps1",
      "${path.root}/../common/scripts/22-enable-icmp.ps1",
      "${path.root}/../common/scripts/23-enable-ems-serial.ps1",
      "${path.root}/../common/scripts/24-configure-winrm-for-ansible.ps1",
      // EMS/SAC on COM1 so the serials=["socket"] device actually carries a
      // Windows console (self-verifies via bcdedit /enum).
      "${path.root}/../common/scripts/30-set-temp.ps1",
      // 53-install-winget was previously omitted here because Add-AppxPackage
      // cannot deploy from the scheduled-task session elevated_user creates
      // (HRESULT 0x80073D19 "a user was logged off"). The script now uses
      // Add-AppxProvisionedPackage -Online instead, which works from a
      // non-interactive/SYSTEM context, and asserts winget.exe resolves
      // afterwards rather than assuming. Server 2022 still lacks the
      // Microsoft.WindowsAppRuntime framework newer App Installer bundles want;
      // if that bites, the script fails loudly saying so instead of silently
      // installing nothing.
      "${path.root}/../common/scripts/53-install-winget.ps1",
      "${path.root}/../common/scripts/60-install-cloudbase-init.ps1",
      // 80-desktop-info replaced 80-bginfo. BGInfo needed a binary .bgi config
      // that only its GUI can author, hosted behind a lab share token that had
      // been committed to git, plus a Sysinternals download this VLAN could not
      // reliably reach. The same fields are a dozen lines of PowerShell, so it
      // is now plain text in-repo with no download and no token. It renders at
      // every LOGON, not once at build time: a wallpaper baked into a template
      // would confidently display the BUILD VM's hostname, IP and disks on
      // every clone.
      "${path.root}/../common/scripts/80-desktop-info.ps1",
      "${path.root}/../common/scripts/81-customization.ps1",
      "${path.root}/../common/scripts/998-cleanup.ps1",
      // sysprep breaks WinRM; keep it last and disabled until the flow is proven.
      // "${path.root}/../common/scripts/999-sysprep.ps1",
    ]
  }

  // Flip the finished template from SATA/e1000 to virtio-scsi/virtio-net.
  // Runs against the Proxmox API after the template is created, because
  // proxmox-clone inherits the base's hardware and exposes no bus setting.
  post-processor "shell-local" {
    // Gating is done inside the script via SWITCH_TO_VIRTIO, NOT with `only`.
    // An empty `only` list means "no source filter", i.e. run everywhere — so
    // `only = cond ? [...] : []` silently runs the post-processor when the
    // condition is FALSE. That shipped a 2025 template on virtio-scsi that
    // boots into the Recovery Environment, exactly what the flag was meant to
    // prevent.
    // environment_vars, not inline args: switch-template-to-virtio.py reads the
    // Proxmox connection from the environment, matching
    // builds/linux/common/scripts/finalize-template-config.py. Omitting these
    // fails the post-processor with "PROXMOX_URL is required" *after* the
    // template has been converted, and packer then deletes it as a failed
    // artifact — losing a 16-minute build for a missing variable.
    environment_vars = [
      "PROXMOX_URL=${local.proxmox_url}",
      "PROXMOX_USERNAME=${local.proxmox_user}",
      "PROXMOX_PASSWORD=${local.proxmox_password}",
      "PROXMOX_NODE=${local.proxmox_node}",
      "PROXMOX_VM_ID=${var.vm_id}",
      "PROXMOX_STORAGE=${local.storage_pool}",
      "SWITCH_TO_VIRTIO=${var.switch_to_virtio}",
      "WINDOWS_OSTYPE=${var.windows_ostype}",
    ]
    command = "${path.root}/../common/scripts/switch-template-to-virtio.py"
  }
}
