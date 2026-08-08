# Install the QEMU guest agent during the pre-WinRM bootstrap phase.
#
# Packer's Proxmox builder discovers a VM's IP address by asking the QEMU guest
# agent. A Microsoft evaluation VHD has no agent installed, so without this the
# build sits at "Waiting for WinRM to become available..." indefinitely even
# though the guest booted fine and holds a DHCP lease — the address simply is
# not visible to Packer.
#
# The full virtio-win-guest-tools.exe (03-install-virtio-guest-tools.ps1) also
# installs the agent, but that runs as a *provisioner*, i.e. only after Packer
# has already connected. Hence the chicken-and-egg, and hence this small
# agent-only MSI which runs from bootstrap.ps1 before WinRM is needed.
#
# Deliberately non-fatal: the ISO builds share bootstrap.ps1 and may not have
# the virtio CD attached at this point, and a missing agent must not abort them.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    $msi = $null
    foreach ($drive in (Get-WmiObject Win32_CDROMDrive | Select-Object -ExpandProperty Drive)) {
        $candidate = Join-Path $drive "guest-agent\qemu-ga-x86_64.msi"
        if (Test-Path $candidate) { $msi = $candidate; break }
    }

    if (-not $msi) {
        Write-Host "qemu-ga MSI not found on any CD-ROM; skipping (agent-dependent IP discovery may fail)"
        exit 0
    }

    Write-Host "Installing QEMU guest agent from $msi"
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "qemu-ga installer returned $($p.ExitCode)"
        exit 0
    }

    # The service must actually be running for the Proxmox API to answer
    # `qm agent <vmid> ping`, which is what the builder polls.
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name "QEMU-GA" -StartupType Automatic
        if ($svc.Status -ne "Running") { Start-Service -Name "QEMU-GA" }
        Write-Host "QEMU-GA service: $((Get-Service -Name 'QEMU-GA').Status)"
    } else {
        Write-Host "QEMU-GA service not registered after install"
    }
}
catch {
    Write-Host "qemu-ga install failed (non-fatal): $($_.Exception.Message)"
    exit 0
}
