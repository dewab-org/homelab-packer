###############################################################################
# Name:             13-install-vm-tools.ps1
# Description:      Find and run the VMware Tools installer on an attached
#                   CD-ROM, then verify the VMTools service is registered,
#                   start mode Auto and Running.
# Author:           Daniel Whicker
# Date:             2021-05-29
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\13-install-vm-tools.txt (append).
#   2. Scans CD-ROM drives for setup64.exe, then setup.exe, preferring the
#      64-bit entry point; either is valid VMware Tools media.
#   3. Runs the installer with /s /v "/qn REBOOT=ReallySuppress" and captures
#      the exit code.
#   4. Polls up to 60s (12 x 5s) for the "VMTools" service to register.
#   5. Sets VMTools to Automatic, reads the start mode back, starts the
#      service if it is not Running, and re-reads its status.
#
# WHAT IT VERIFIES
#   - An installer was found on some CD-ROM; the error names the drives that
#     were seen, so "is the VMware Tools ISO attached?" is answerable from the
#     log alone.
#   - Installer exit code is 0 or 3010 (ERROR_SUCCESS_REBOOT_REQUIRED,
#     expected with REBOOT=ReallySuppress). Returning 0 is not evidence that
#     anything installed, which is why the checks below exist.
#   - The "VMTools" service is registered. Registration can lag the installer
#     by a few seconds, hence the poll; absence after it means the installer
#     reported success while installing nothing.
#   - Start mode reads back "Auto". Set-Service returning is not proof: a
#     template whose tools service is left Manual boots without tools and
#     nothing complains until something actually needs them.
#   - The service is Running.
#
# FAILURE CONTRACT
#   FATAL     : installer not found on any CD-ROM, an installer exit code
#               other than 0/3010, VMTools unregistered after the poll, a
#               start mode other than Auto, or a service that will not reach
#               Running. Each throws and exits 1.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the
#           failure is readable before Packer destroys the VM. Unset: exit
#           immediately.
#
# NOTES
#   - Not used by the Proxmox/QEMU builds (those use
#     10-install-virtio-guest-tools.ps1 and 00-install-qemu-ga.ps1). Kept in
#     the library for a possible VMware target.
#   - The installer media used to be hardcoded to E:\setup.exe, which silently
#     pointed at whatever happened to be mounted as E:. The drive is now
#     discovered instead.
#   - The transcript name tracks the script number; it was renamed from
#     00-vmtools.txt when the library was renumbered by execution phase.
#   - The success `exit 0` lives INSIDE the try on purpose: Packer runs this
#     as `... ; exit $LastExitCode`, so falling off the end would hand the
#     build's verdict to a stale $LASTEXITCODE from the last native call, and
#     placing it after the try/catch would mask a caught failure. `exit` still
#     runs the finally, so the transcript is closed.
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/13-install-vm-tools.txt' -Append

function Get-VMwareToolsInstaller {
    # VMware Tools media carries setup.exe (32-bit stub) and setup64.exe.
    # Either is a valid entry point; prefer setup64.exe when present.
    $drives = Get-CimInstance -ClassName Win32_CDROMDrive |
        Select-Object -ExpandProperty Drive |
        Where-Object { $_ }
    foreach ($drive in $drives) {
        foreach ($name in @('setup64.exe', 'setup.exe')) {
            $candidate = Join-Path $drive $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

try {
    $installer = Get-VMwareToolsInstaller
    if (-not $installer) {
        $seen = (Get-CimInstance -ClassName Win32_CDROMDrive |
            Select-Object -ExpandProperty Drive) -join ', '
        throw "VMware Tools setup.exe not found on any CD-ROM (drives seen: '$seen'). Is the VMware Tools ISO attached?"
    }

    Write-Host "Installing VMware Tools from $installer"
    $installArguments = @('/s', '/v', '/qn REBOOT=ReallySuppress')
    $proc = Start-Process -FilePath $installer -ArgumentList $installArguments -Wait -PassThru -NoNewWindow
    # 3010 == ERROR_SUCCESS_REBOOT_REQUIRED, expected with REBOOT=ReallySuppress.
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "VMware Tools installer exited with code $($proc.ExitCode)"
    }
    Write-Host "Installer exit code: $($proc.ExitCode)"

    # Verify the effect, not the return code: the tools service must be
    # registered. Service registration can lag the installer by a few seconds.
    $svc = $null
    for ($i = 0; $i -lt 12; $i++) {
        $svc = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
        if ($svc) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $svc) {
        throw "VMware Tools installer reported success but the 'VMTools' service is not registered"
    }

    Set-Service -Name 'VMTools' -StartupType Automatic
    # Read the start mode back. Set-Service returning is not proof: a template
    # whose tools service is left Manual boots without tools and nothing
    # complains until something actually needs them.
    $startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='VMTools'").StartMode
    if ($startMode -ne 'Auto') {
        throw "'VMTools' start mode read back as '$startMode', expected 'Auto'"
    }

    if ($svc.Status -ne 'Running') { Start-Service -Name 'VMTools' }
    $svc = Get-Service -Name 'VMTools'
    if ($svc.Status -ne 'Running') {
        throw "'VMTools' service is registered but not Running (status: $($svc.Status))"
    }
    Write-Host "VMTools service verified: $($svc.Status), start mode $startMode"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE the last native call left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "VMware Tools installation FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    # Optional hold so the failure is readable before Packer destroys the VM.
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
