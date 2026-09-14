###############################################################################
# Name:             00-install-qemu-ga.ps1
# Description:      Install the QEMU guest agent MSI from an attached CD during
#                   the pre-WinRM first-logon bootstrap, then verify the
#                   QEMU-GA service is registered, Auto and Running.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Deletes any stale C:\Windows\Temp\qemu-ga.failed marker so the file
#      always reflects the current run.
#   2. Enumerates CD-ROM drives and looks for
#      <drive>\guest-agent\qemu-ga-x86_64.msi on each.
#   3. Runs `msiexec /i <msi> /qn /norestart` and waits for it.
#   4. Polls up to 60s (12 x 5s) for the "QEMU-GA" service to appear.
#   5. Sets QEMU-GA to start type Automatic, reads the start mode back, starts
#      the service if it is not already Running, and re-reads its status.
#
# WHAT IT VERIFIES
#   - The MSI exists on some CD-ROM. Failure means no agent is installed and
#     Packer's Proxmox builder will never see the VM's IP.
#   - msiexec exit code is 0 or 3010 (ERROR_SUCCESS_REBOOT_REQUIRED). Anything
#     else means the install did not complete.
#   - The "QEMU-GA" service is registered. Failure means msiexec returned
#     success while installing nothing - the classic silent no-op.
#   - Start mode reads back "Auto". Failure means the agent runs now but is
#     absent after the next boot, which is exactly when a clone must report
#     its IP.
#   - Service status is "Running". Failure means `qm agent <vmid> ping`, which
#     the builder polls, will not answer.
#
# FAILURE CONTRACT
#   FATAL     : nothing. This script never exits non-zero.
#   LOUD SKIP : every failure above - MSI missing, bad msiexec exit code,
#               service unregistered, wrong start mode, not Running, or any
#               thrown exception - prints a banner, writes to the warning
#               stream, drops C:\Windows\Temp\qemu-ga.failed and exits 0.
#               Acceptable because bootstrap-vhd.ps1 calls this inside a
#               single try{} that also calls 01-enable-winrm.ps1, so a throw
#               would skip WinRM entirely and turn a missing guest agent into
#               a guaranteed 90-minute Packer connect timeout. A non-zero exit
#               is no better: bootstrap-vhd.ps1 falls off its end without an
#               explicit exit, so a lingering $LASTEXITCODE can leak out as
#               the first-logon command's exit code and abort the logon
#               sequence. The marker is not a dead end -
#               04-assert-bootstrap-clean.ps1 reads it once WinRM is up and
#               fails the build there.
#
# NOTES
#   - CONSEQUENCE, so nobody is misled by the caller's log: because this
#     script exits 0, bootstrap.ps1's Invoke-BootstrapStep prints
#     "install QEMU guest agent : ok" even when the agent was NOT installed.
#     The banner, the warning stream and $MarkerPath are the real verdict --
#     not that line. If the agent is missing, IP discovery is what breaks.
#   - Why this exists at all: a Microsoft evaluation VHD has no agent
#     installed, so without this the build sits at "Waiting for WinRM to
#     become available..." indefinitely even though the guest booted fine and
#     holds a DHCP lease - the address simply is not visible to Packer.
#   - The full virtio-win-guest-tools.exe (10-install-virtio-guest-tools.ps1)
#     also installs the agent, but that runs as a *provisioner*, i.e. only
#     after Packer has already connected. Hence the chicken-and-egg, and hence
#     this small agent-only MSI which runs from bootstrap.ps1.
#   - Deliberately tolerant of a missing CD: the ISO builds share
#     bootstrap.ps1 and may not have the virtio CD attached at this point, and
#     a missing agent must not abort Windows Setup.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$MarkerPath = "C:\Windows\Temp\qemu-ga.failed"

function Write-QemuGaFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "########################################################"
    Write-Host "## QEMU GUEST AGENT NOT INSTALLED (non-fatal, but the"
    Write-Host "## Proxmox builder discovers the VM IP via this agent):"
    Write-Host "##   $Message"
    Write-Host "## Marker written to $MarkerPath"
    Write-Host "########################################################"
    # Also on the warning stream: the caller logs this step as "ok" (see header),
    # so Write-Host alone can be scrolled past in a long bootstrap transcript.
    Write-Warning "QEMU guest agent NOT installed: $Message"
    try {
        $Message | Out-File -FilePath $MarkerPath -Encoding ascii -Force
    }
    catch {
        Write-Host "## Could not write marker file: $($_.Exception.Message)"
    }
}

try {
    # Clear a marker from a previous attempt so the file always reflects the
    # current run rather than a stale failure.
    if (Test-Path -LiteralPath $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force }

    $msi = $null
    $drives = Get-CimInstance -ClassName Win32_CDROMDrive |
        Select-Object -ExpandProperty Drive |
        Where-Object { $_ }
    foreach ($drive in $drives) {
        $candidate = Join-Path $drive "guest-agent\qemu-ga-x86_64.msi"
        if (Test-Path -LiteralPath $candidate) { $msi = $candidate; break }
    }

    if (-not $msi) {
        Write-QemuGaFailure "qemu-ga MSI not found on any CD-ROM (drives seen: '$($drives -join ', ')')"
        exit 0
    }

    # This script is a FALLBACK. 10-install-virtio-guest-tools.ps1 runs first in
    # bootstrap and its package already contains the guest agent, so by the time
    # we get here the service is usually present and Running. Re-running the
    # standalone MSI over that install returns 1603 ("fatal error"), which is
    # really just "already installed" - and recording that as a bootstrap
    # failure fails the whole build for a step that had nothing left to do.
    # Observed exactly that: virtio-guest-tools.failed absent, qemu-ga.failed
    # present with 1603, build correctly aborted by 04-assert-bootstrap-clean.
    #
    # So: if the agent is already registered AND Running, this script's job is
    # done. Say so and succeed, rather than reinstalling to prove a point.
    $existing = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -eq 'Running') {
        Write-Host "QEMU-GA is already registered and Running (installed by the"
        Write-Host "VirtIO guest tools). Nothing to do - skipping the standalone MSI."
        exit 0
    }
    if ($existing) {
        Write-Host "QEMU-GA is registered but $($existing.Status); starting it rather than reinstalling."
        Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        $existing = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        if ($existing -and $existing.Status -eq 'Running') {
            Write-Host "QEMU-GA started successfully; skipping the standalone MSI."
            exit 0
        }
        Write-Host "QEMU-GA would not start; falling through to a reinstall."
    }

    Write-Host "Installing QEMU guest agent from $msi"
    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    # 3010 == ERROR_SUCCESS_REBOOT_REQUIRED.
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-QemuGaFailure "msiexec returned exit code $($proc.ExitCode) for $msi"
        exit 0
    }
    Write-Host "msiexec exit code: $($proc.ExitCode)"

    # Verify the effect: msiexec can return 0 without leaving a usable agent.
    # The service must actually be Running for the Proxmox API to answer
    # `qm agent <vmid> ping`, which is what the builder polls.
    $svc = $null
    for ($i = 0; $i -lt 12; $i++) {
        $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        if ($svc) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $svc) {
        Write-QemuGaFailure "msiexec reported success but the 'QEMU-GA' service is not registered"
        exit 0
    }

    Set-Service -Name "QEMU-GA" -StartupType Automatic
    # Read the start mode back: Set-Service returning is not proof it stuck, and
    # an agent left on Manual is Running now but absent after the next boot -
    # which is exactly when Packer needs it to report the clone's IP.
    $startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='QEMU-GA'").StartMode
    if ($startMode -ne "Auto") {
        Write-QemuGaFailure "'QEMU-GA' start mode read back as '$startMode', expected 'Auto'"
        exit 0
    }

    if ($svc.Status -ne "Running") { Start-Service -Name "QEMU-GA" }
    $svc = Get-Service -Name "QEMU-GA"
    if ($svc.Status -ne "Running") {
        Write-QemuGaFailure "'QEMU-GA' service is registered but not Running (status: $($svc.Status))"
        exit 0
    }
    Write-Host "QEMU-GA service verified: $($svc.Status), start mode $startMode"

    # Explicit success exit, INSIDE the try, matching the loud-skip paths above.
    # Falling off the end would leave the caller reading whatever stale
    # $LASTEXITCODE the last native command happened to set.
    exit 0
}
catch {
    Write-QemuGaFailure "qemu-ga install threw: $($_.Exception.Message)"
    exit 0
}
