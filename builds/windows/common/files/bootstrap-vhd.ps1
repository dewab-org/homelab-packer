# Pre-WinRM bootstrap for VHD/VHDX clone builds.
#
# Deliberately minimal — only the two things Packer needs before it can connect:
#
#   1. QEMU guest agent, because the Proxmox builder discovers the VM's IP by
#      querying the agent. A vendor image has none, so without this Packer waits
#      on WinRM forever while the guest sits happily on a DHCP lease.
#   2. WinRM itself.
#
# Everything else (RDP, OpenSSH, Ansible remoting, virtio guest tools, ...) runs
# as a normal provisioner once Packer is connected. That is not just tidiness:
# the shared ISO bootstrap also runs 12-enable-openssh here, and
# Add-WindowsCapability blocks on Windows Update, which on this image hung the
# whole bootstrap indefinitely. Anything that can wait until after the
# connection should wait.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Start-Transcript -Path "C:\Windows\Temp\packer-bootstrap.txt" -Append
try {
    $mediaRoot = $PSScriptRoot
    if (-not $mediaRoot -or -not (Test-Path $mediaRoot)) {
        throw "Unable to determine PACKER media root"
    }
    New-Item -Path "C:\Install" -ItemType Directory -Force | Out-Null
    New-Item -Path "C:\Install\scripts" -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $mediaRoot "scripts\*.ps1") -Destination "C:\Install\scripts" -Force

    # Full virtio guest tools, not just the agent MSI. Installing qemu-ga alone
    # is not enough: the agent reaches the host over a virtio-serial channel,
    # and a vendor image has no virtio-serial driver, so `qm agent ping` keeps
    # reporting "not running" even while the service is Running inside the
    # guest — observed exactly that. The guest-tools installer supplies
    # vioser (and viostor/vioscsi/netkvm, which the post-build bus switch needs)
    # along with the agent.
    & "C:\Install\scripts\03-install-virtio-guest-tools.ps1"

    # Fallback: if the bundle did not register the agent for any reason, the
    # agent-only MSI is cheap to retry and is a no-op when already present.
    & "C:\Install\scripts\01-install-qemu-ga.ps1"

    & "C:\Install\scripts\02-enable-winrm.ps1"
}
catch {
    Write-Host "bootstrap failed: $($_.Exception.Message)"
    "bootstrap failed: $($_.Exception.Message)" | Out-File -FilePath "C:\Windows\Temp\packer-bootstrap.failed" -Encoding ascii -Force
    exit 0
}
Stop-Transcript
