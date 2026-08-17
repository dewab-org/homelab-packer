###############################################################################
# Name:             33-change-cdrom-drive-letter.ps1
# Description:      Moves the optical (CD-ROM) drive to a high drive letter,
#                   Z: by default, so the usual data-disk letter (D:) is
#                   free. The optical drive is discovered rather than assumed
#                   to be at D:, the move is verified, and the release of the
#                   old letter is verified separately.
# Author:           Daniel Whicker
# Date:             2024-07-09
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and opens a transcript at
#      C:\Install\33-change-cdrom-drive-letter.txt.
#   2. AZURE GUARD: queries the Azure instance metadata service at
#      http://169.254.169.254/metadata/instance with a 3-second timeout. If
#      it answers, this is an Azure VM, where drive letters are managed by
#      the platform - the script logs SKIPPED and exits 0 without touching
#      anything. Any failure of that call means "not Azure", which is the
#      normal Proxmox case, and the script continues.
#   3. Enumerates Win32_CDROMDrive instances that hold a drive letter.
#   4. Confirms the target letter is unoccupied, then reassigns the optical
#      volume's DriveLetter with Set-CimInstance.
#
# WHAT IT VERIFIES
#   - Exactly one lettered optical drive exists. Two or more is fatal: the
#     script refuses to guess which one to move.
#   - The target letter is genuinely free, queried with -ErrorAction Stop so
#     a failed CIM query cannot be mistaken for "the letter is free".
#   - A Win32_Volume actually exists for the drive's current letter before
#     attempting to reassign it.
#   - The optical drive really appears at the target letter afterwards,
#     polled 10 times at 1-second intervals because the mount point change
#     is asynchronous - Set-CimInstance returns before it has happened.
#   - The OLD letter has actually been released. Freeing that letter is the
#     entire point of the move, and the drive showing up at the target does
#     not by itself prove the old mount point was given up.
#
# FAILURE CONTRACT
#   FATAL     : more than one lettered optical drive; the target letter
#               already in use by another volume; no Win32_Volume for the
#               drive's current letter; the drive not present at the target
#               after ~10s of polling; the old letter still occupied after
#               the move. All exit 1 and fail the provisioner.
#   LOUD SKIP : (a) Azure instance metadata responds - the platform owns
#               drive letters there, so moving one would fight it, and the
#               D:-is-free problem this script solves does not apply.
#               (b) No optical drive holds a drive letter at all - there is
#               nothing occupying a letter, so nothing to move.
#               (c) The optical drive is already at the target letter.
#               All three log the reason and exit 0, because in each case
#               the desired end state is already true (or unreachable by
#               design) rather than unverified.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
#   Note this script also takes a -TargetDriveLetter parameter (default Z,
#   validated to D-Z so the system and reserved letters cannot be taken).
#   Packer's powershell provisioner runs scripts without arguments, so in a
#   build it is always the default.
#
# NOTES
#   - The -TimeoutSec 3 on the Azure metadata probe matters a great deal.
#     On a Proxmox VM 169.254.169.254 is simply unreachable, and
#     Invoke-RestMethod's 100-second default would stall the whole
#     provisioner on every single build.
#   - Get-CimInstance, not Get-WmiObject: the WMI cmdlets were removed in
#     PowerShell 7 and this script has to keep working under pwsh.
#   - No reboot is required; the drive-letter change is live as soon as the
#     verification loop observes it. (Contrast 31-disable-ipv6.ps1, whose
#     registry half only takes effect at the next boot - and note there is
#     NO windows-restart provisioner anywhere in this repo if one is ever
#     needed.)
#   - NOT WIRED INTO ANY BUILD. As of this writing no *.pkr.hcl in this
#     repo references 33-change-cdrom-drive-letter.ps1 - not the 2022/2025
#     Core or Desktop Experience ISO builds, and not the cloud-clone build.
#     It is a library script that nothing currently runs, so do not assume
#     the shipped templates have their optical drive on Z:.
#   - The explicit 'exit 0' is load-bearing. Packer's default powershell
#     execute_command ends with 'exit $LastExitCode', which would otherwise
#     propagate whatever a stale native command left behind.
###############################################################################

[CmdletBinding()]
param(
    # Letter to move the optical drive to. A-C are excluded on purpose.
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$TargetDriveLetter = 'Z'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = 'C:/Install/33-change-cdrom-drive-letter.txt'
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path $logPath -Append -Force

try {
    ###########################################################################
    # Azure guard
    ###########################################################################
    # -TimeoutSec 3 matters: on a Proxmox VM 169.254.169.254 is simply
    # unreachable and the default (100s) stalls the whole provisioner.
    $azureMetadata = $null
    try {
        $azureMetadata = Invoke-RestMethod -Headers @{ 'Metadata' = 'true' } -Method GET `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
            -TimeoutSec 3 -ErrorAction SilentlyContinue
    }
    catch {
        # Any failure here means "not Azure", which is the normal case.
        $azureMetadata = $null
    }

    if ($azureMetadata) {
        Write-Host "SKIPPED: running on an Azure VM, where drive letters are managed by the platform. The optical drive was NOT moved."
        exit 0
    }

    ###########################################################################
    # Discover the optical drive
    ###########################################################################
    $target = '{0}:' -f $TargetDriveLetter.ToUpper()

    # Get-CimInstance, not Get-WmiObject: the WMI cmdlets were removed in
    # PowerShell 7 and this script has to keep working under pwsh.
    $opticalDrives = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction Stop |
        Where-Object { $_.Drive })

    if ($opticalDrives.Count -eq 0) {
        Write-Host "SKIPPED: no optical drive holds a drive letter, so none can be occupying $target's neighbours. Nothing was moved."
        exit 0
    }

    if ($opticalDrives.Count -gt 1) {
        throw ("Expected at most one optical drive, found {0} ({1}). Refusing to guess which one to move." -f
            $opticalDrives.Count, (($opticalDrives | ForEach-Object { $_.Drive }) -join ', '))
    }

    $current = $opticalDrives[0].Drive
    Write-Host "Optical drive '$($opticalDrives[0].Caption)' is currently at $current"

    if ($current -eq $target) {
        Write-Host "Optical drive is already at $target; nothing to do."
        exit 0
    }

    ###########################################################################
    # The target letter has to be free before we can take it
    ###########################################################################
    # -ErrorAction Stop, not SilentlyContinue: a failed CIM query must not be
    # mistaken for "the letter is free".
    $occupied = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$target'" -ErrorAction Stop
    if ($occupied) {
        throw "Drive letter $target is already in use by '$($occupied.Label)' ($($occupied.DeviceID)). Refusing to reassign it."
    }

    ###########################################################################
    # Move it
    ###########################################################################
    $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$current'" -ErrorAction Stop
    if ($null -eq $volume) {
        throw "Optical drive reports drive letter $current but no Win32_Volume exists for it; cannot reassign the letter."
    }

    Write-Host "Moving optical drive from $current to $target..."
    Set-CimInstance -InputObject $volume -Property @{ DriveLetter = $target } -ErrorAction Stop

    ###########################################################################
    # Verify the effect - the mount point change is asynchronous
    ###########################################################################
    $moved = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        Start-Sleep -Seconds 1
        $check = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue |
            Where-Object { $_.Drive -eq $target })
        if ($check.Count -gt 0) {
            $moved = $true
            break
        }
    }

    if (-not $moved) {
        $stillAt = (Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Drive }) -join ', '
        throw "Set-CimInstance reported success but the optical drive is not at $target (still at: $stillAt)."
    }

    # The whole point of the move is to FREE the old letter. Assert that too -
    # the drive appearing at $target does not by itself prove $current was
    # released.
    $stillOccupied = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$current'" -ErrorAction Stop
    if ($stillOccupied) {
        throw "Optical drive is now at $target but $current is still occupied by '$($stillOccupied.Label)' ($($stillOccupied.DeviceID)); the letter was not freed."
    }

    Write-Host "Verified: optical drive moved from $current to $target, and $current is now free."

    # Explicit success code. Packer's default powershell execute_command ends
    # with 'exit $LastExitCode', which would otherwise propagate whatever a
    # stale native command left behind.
    exit 0
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Optional debug hold so the error is readable before Packer destroys the VM.
    if ($env:PACKER_DEBUG_HOLD) {
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
