###############################################################################
# Name:             10-install-virtio-guest-tools.ps1
# Description:      Run virtio-win-guest-tools.exe from an attached CD-ROM,
#                   then verify the QEMU-GA service is registered, Auto and
#                   Running and that a VirtIO driver payload is present.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\10-install-virtio-guest-tools.txt.
#   2. Deletes any stale C:\Windows\Temp\virtio-guest-tools.failed marker.
#   3. Scans CD-ROM drives for virtio-win-guest-tools.exe at the media root.
#   4. Runs it with /install /quiet /norestart and captures the exit code.
#   5. Polls up to 60s (12 x 5s) for the "QEMU-GA" service, sets it to
#      Automatic, reads the start mode back, starts it if it is not Running
#      and re-reads the status.
#   6. Looks for evidence of the VirtIO driver payload via three independent
#      signals, in order: a matching package in `pnputil /enum-drivers`, a
#      bound Red Hat / VirtIO PnP device, or a Virtio-Win directory under
#      Program Files (x86 included).
#
# WHAT IT VERIFIES
#   - The installer exists on some CD-ROM. Failure means nothing was run.
#   - The installer exit code is RECORDED, not trusted. 0 and 3010
#     (ERROR_SUCCESS_REBOOT_REQUIRED, expected with /norestart) are normal;
#     anything else prints a loud banner but does NOT by itself fail the
#     script. virtio-win-guest-tools.exe has been seen returning 1603 on an
#     install that genuinely worked - agent registered, driver bound, Packer
#     connected - so the effect checks below are the real gate. A 0 does not
#     prove success and a non-zero does not prove failure; the code is carried
#     into the failure message so it is available as a clue when they fail.
#   - "QEMU-GA" is registered. Failure means the installer reported success
#     while installing nothing.
#   - Start mode reads back "Auto". Set-Service returning is not proof it
#     stuck, and an agent left on Manual is Running now but gone after the
#     next boot - exactly when the clone needs to report its IP.
#   - The service is Running, which is what `qm agent <vmid> ping` and
#     therefore Packer's IP discovery need.
#   - Some VirtIO driver evidence is found. Note the limit: this is a
#     three-way heuristic, not a targeted check. Any of virtio/redhat/netkvm/
#     vioscsi/viostor/vioser/balloon in the driver store satisfies it, and the
#     Program Files fallback proves only that files were laid down, not that
#     vioser - the serial driver the agent actually talks over - bound to a
#     device. It catches a wholesale no-op, not a partial driver failure.
#
# FAILURE CONTRACT
#   FATAL     : installer not found, QEMU-GA absent, start mode not Auto,
#               service not Running, or no VirtIO driver evidence at all. Each
#               throws, writes the reason to
#               C:\Windows\Temp\virtio-guest-tools.failed and exits 1.
#               NOT fatal on its own: an unexpected installer exit code (see
#               above) - it is reported and the effect checks decide.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the VM can
#           be inspected before Packer destroys it. Unset: exit immediately.
#
# NOTES
#   - Load-bearing: Packer's Proxmox builder finds the VM's IP by querying the
#     QEMU guest agent, and the agent only reaches the host over the
#     virtio-serial driver this bundle supplies. Without vioser the agent runs
#     happily inside the guest while the host still reports it as down.
#   - The installer's exit code used to be discarded entirely (Start-Process
#     -Wait with no -PassThru), so a no-op install looked identical to a good
#     one and surfaced later as a WinRM timeout.
#   - A non-zero exit from `pnputil /enum-drivers` is logged and tolerated;
#     the PnP and directory checks then carry the verification.
#   - The marker file exists because bootstrap-vhd.ps1 swallows provisioner
#     errors; 04-assert-bootstrap-clean.ps1 is what reads it back.
#   - The success `exit 0` lives INSIDE the try on purpose: Packer runs this
#     as `... ; exit $LastExitCode`, so falling off the end would hand the
#     build's verdict to whatever stale $LASTEXITCODE the last native call
#     (pnputil) left behind, and placing it after the try/catch would mask a
#     caught failure. `exit` still runs the finally, closing the transcript.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$MarkerPath = "C:\Windows\Temp\virtio-guest-tools.failed"

Start-Transcript -Path "C:/Install/10-install-virtio-guest-tools.txt" -Append

function Get-GuestToolsInstaller {
    $drives = Get-CimInstance -ClassName Win32_CDROMDrive |
        Select-Object -ExpandProperty Drive |
        Where-Object { $_ }
    foreach ($drive in $drives) {
        $path = Join-Path $drive "virtio-win-guest-tools.exe"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Test-VirtioDriverPresent {
    # Three independent signals; any one is proof the driver payload installed.
    # 1. A Red Hat / VirtIO driver package in the driver store.
    $inStore = $false
    $drivers = pnputil /enum-drivers 2>&1
    if ($LASTEXITCODE -eq 0) {
        $inStore = [bool]($drivers | Select-String -Pattern 'virtio|redhat|netkvm|vioscsi|viostor|vioser|balloon' -Quiet)
    }
    else {
        Write-Host "pnputil /enum-drivers returned $LASTEXITCODE; falling back to PnP/driver-directory checks"
    }
    if ($inStore) { return $true }

    # 2. A bound Red Hat PnP device (only present when a virtio device exists).
    $signed = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DriverProviderName -like '*Red Hat*' -or $_.DeviceName -like '*VirtIO*' })
    if ($signed.Count -gt 0) { return $true }

    # 3. Last resort: the installed program directory.
    foreach ($dir in @("$env:ProgramFiles\Virtio-Win", "${env:ProgramFiles(x86)}\Virtio-Win")) {
        if (Test-Path -LiteralPath $dir) { return $true }
    }
    return $false
}

try {
    if (Test-Path -LiteralPath $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force }

    $installer = Get-GuestToolsInstaller
    if (-not $installer) {
        throw "virtio-win-guest-tools.exe not found on attached CD-ROMs"
    }

    Write-Host "Installing $installer"
    $proc = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" `
        -Wait -PassThru -NoNewWindow
    # 3010 == ERROR_SUCCESS_REBOOT_REQUIRED, expected with /norestart.
    #
    # An unexpected exit code is recorded but NOT thrown on here, deliberately.
    # virtio-win-guest-tools.exe has been observed returning 1603 ("fatal error
    # during installation") on a clean first-logon install that in fact worked:
    # the QEMU-GA service was registered and Running, the vioser driver bound,
    # and Packer connected over WinRM immediately afterwards. Throwing on the
    # code aborted the build over an installer whose effect was correct.
    #
    # This repo's rule is to verify the EFFECT rather than trust the return
    # code, and that cuts both ways: a 0 does not prove success, and a non-zero
    # does not prove failure. The verification below is the real gate - if the
    # agent and drivers are genuinely absent it throws there, and the exit code
    # recorded here is included so the log explains what happened.
    $installerExitCode = $proc.ExitCode
    if ($installerExitCode -ne 0 -and $installerExitCode -ne 3010) {
        Write-Host "########################################################"
        Write-Host "## virtio-win-guest-tools.exe returned $installerExitCode"
        Write-Host "## (not 0/3010). NOT failing on that alone - the effect"
        Write-Host "## checks below decide. If they pass, the install worked"
        Write-Host "## despite the code; if they fail, this code is the clue."
        Write-Host "########################################################"
    }
    Write-Host "Installer exit code: $installerExitCode"

    # ---- Verify the effect, not the return code --------------------------------

    # 1. QEMU guest agent service must exist and be Running: this is what
    #    `qm agent <vmid> ping` (and therefore Packer's IP discovery) needs.
    $svc = $null
    for ($i = 0; $i -lt 12; $i++) {
        $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        if ($svc) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $svc) {
        throw "'QEMU-GA' service is not registered after the guest tools install (installer exit code was $installerExitCode)"
    }
    Set-Service -Name "QEMU-GA" -StartupType Automatic
    # Read the start mode back: Set-Service returning is not proof it stuck, and
    # an agent left on Manual is Running now but gone after the next boot -
    # exactly when the clone needs to report its IP.
    $startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='QEMU-GA'").StartMode
    if ($startMode -ne "Auto") {
        throw "'QEMU-GA' start mode read back as '$startMode', expected 'Auto' (installer exit code was $installerExitCode)"
    }
    if ($svc.Status -ne "Running") { Start-Service -Name "QEMU-GA" }
    $svc = Get-Service -Name "QEMU-GA"
    if ($svc.Status -ne "Running") {
        throw "'QEMU-GA' service is registered but not Running (status: $($svc.Status); installer exit code was $installerExitCode)"
    }
    Write-Host "QEMU-GA service verified: $($svc.Status), start mode $startMode"

    # 2. At least one VirtIO driver must be present. Without vioser the agent
    #    runs happily inside the guest while the host still reports it as down.
    if (-not (Test-VirtioDriverPresent)) {
        throw "No VirtIO/Red Hat driver found in the driver store, in PnP, or under Program Files after install (installer exit code was $installerExitCode)"
    }
    Write-Host "VirtIO driver payload verified present"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE the last native call (pnputil)
    # left behind. It must not live after the try/catch, or it would mask a
    # caught failure. `exit` still runs the finally below.
    exit 0
}
catch {
    # bootstrap-vhd.ps1 swallows provisioner errors, so leave a marker behind.
    Write-Host "virtio guest tools install FAILED: $($_.Exception.Message)"
    try {
        $_.Exception.Message | Out-File -FilePath $MarkerPath -Encoding ascii -Force
    }
    catch {
        Write-Host "Could not write marker file $($MarkerPath): $($_.Exception.Message)"
    }

    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    # Non-zero so the provisioner fails; the finally below still closes the
    # transcript. Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
