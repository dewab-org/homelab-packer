###############################################################################
# Name:             999-sysprep.ps1
# Description:      Generalize the image with Sysprep before templating. It
#                   REFUSES to run without an unattend answer file, asserts the
#                   platform is Proxmox/QEMU, and verifies the generalized
#                   state afterwards rather than trusting the exit code.
# Author:           Daniel Whicker
# Date:             2024-05-02
###############################################################################
#
# ##########################################################################
# # WARNING: SYSPREP BREAKS WINRM. THIS MUST BE THE FINAL PROVISIONER.     #
# #                                                                        #
# # /generalize tears down the machine SID, the WinRM configuration and    #
# # the listener. Packer cannot run another provisioner afterwards, and    #
# # any script scheduled after this one will simply time out. Re-enable it #
# # LAST in the scripts list, never in the middle.                         #
# ##########################################################################
#
# CURRENT STATE: this script is COMMENTED OUT in every build file that
# references it (the four windows-server-*-iso builds and the cloud-clone
# build), so no shipped template is generalized today. Nothing below runs until
# one of those lines is uncommented.
#
# WHAT IT DOES
#   1. Creates C:\Install, starts the transcript, and prints the WinRM warning.
#   2. Asserts the guest is a Proxmox/QEMU/KVM platform.
#   3. Asserts Sysprep.exe exists under %SystemRoot%\System32\Sysprep.
#   4. Resolves the answer file: -UnattendPath, else PACKER_SYSPREP_UNATTEND,
#      else the first of C:\Install\unattend.xml, C:\Install\files\
#      unattend.xml, <sysprepdir>\unattend.xml, C:\Windows\Panther\
#      unattend.xml that exists.
#   5. Parses that file as XML and inspects its structure.
#   6. Runs Sysprep /oobe /generalize /quiet /quit /unattend:<file>.
#   7. Judges the result on the exit code, setuperr.log and the registry.
#
# WHAT IT VERIFIES
#   - AN UNATTEND FILE EXISTS. Running /generalize /oobe with no /unattend:
#     leaves the specialize/oobeSystem passes unanswered, so every clone halts
#     at the interactive OOBE wizard, never configures the network, never
#     starts WinRM, and looks to Packer and Ansible like a dead VM - forever.
#     Producing that template is worse than failing the build.
#   - The answer file is well-formed XML, its root element is <unattend>, and
#     it contains at least one <settings pass=...> section. Well-formed is not
#     enough: a windowsPE-only Autounattend.xml parses perfectly and still
#     strands every clone at OOBE.
#   - The platform. This is a Proxmox/QEMU repository, so VMware markers or an
#     absence of QEMU/KVM/Bochs/SeaBIOS/Proxmox/OVMF markers is a refusal.
#   - Sysprep's exit code - native failures raise no PowerShell error at all.
#   - setuperr.log, but only if it was written DURING THIS RUN (compared
#     against a timestamp taken before launch). Sysprep can exit 0 and still
#     have logged fatal errors.
#   - THE GENERALIZED STATE ITSELF: HKLM\SYSTEM\Setup\Status\ImageState must
#     contain GENERALIZE, or SysprepStatus\GeneralizationState must be 7. Read
#     for up to 60 seconds, because /quit can return a moment before the status
#     keys settle - the loop tolerates lateness, never absence, and throws when
#     the attempts run out.
#
# FAILURE CONTRACT
#   FATAL     : VMware platform markers, or no QEMU/KVM markers at all;
#               Sysprep.exe missing; no answer file supplied or found; an
#               answer file that is not valid XML, is not rooted at <unattend>,
#               or has no <settings pass=> sections; a non-zero sysprep exit;
#               any error line written to setuperr.log during this run; and the
#               image not reporting a generalized state within 60 seconds. All
#               exit 1 - a non-generalized or half-generalized template must
#               never be called a template.
#   LOUD SKIP : PACKER_SYSPREP_ALLOW_UNKNOWN_PLATFORM=1/true/yes skips the
#               ENTIRE platform assertion (including the VMware refusal) after
#               a banner, and generalization then proceeds. An answer file with
#               no oobeSystem pass prints a banner and CONTINUES, because a
#               specialize-only answer file is legitimate in some flows - but
#               the banner says to verify a clone actually boots before
#               trusting the template.
#
# INPUTS (environment)
#   PACKER_SYSPREP_UNATTEND                 Path to the answer file. This is
#                                           the practical route, since Packer's
#                                           powershell provisioner passes no
#                                           arguments.
#   PACKER_SYSPREP_ALLOW_UNKNOWN_PLATFORM   1/true/yes to skip the hypervisor
#                                           assertion entirely.
#   PACKER_SYSPREP_HOLD_ON_ERROR_SECONDS    Digits only. On failure, hold the
#                                           VM open this long for inspection.
#                                           Default 0 - a silent 60-minute hang
#                                           in CI is its own outage.
#
# NOTES
#   - The old VMware-detection branch has been inverted into an explicit
#     platform assertion. A stale registry key or an odd BIOS string used to
#     make this script SKIP generalization and exit 0, quietly shipping a
#     non-generalized template. It now fails instead.
#   - No single sysprep signal is trustworthy on its own, which is why four are
#     checked and all of them are re-read rather than inferred.
#
###############################################################################

[CmdletBinding()]
param(
    # Path to the sysprep answer file. Falls back to PACKER_SYSPREP_UNATTEND
    # and then to the probed defaults.
    [string]$UnattendPath = $env:PACKER_SYSPREP_UNATTEND
)

# Set preferences to control script behavior
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$sysprepDir = Join-Path $env:SystemRoot "System32\Sysprep"
$sysprepExe = Join-Path $sysprepDir "Sysprep.exe"
$setupErrLog = Join-Path $sysprepDir "Panther\setuperr.log"

# Probed in order when no path is supplied.
$unattendCandidates = @(
    "C:\Install\unattend.xml",
    "C:\Install\files\unattend.xml",
    (Join-Path $sysprepDir "unattend.xml"),
    "C:\Windows\Panther\unattend.xml"
)

# Optional debug aid: hold the VM open after a failure so the guest can be
# inspected before Packer destroys it. Off by default - a silent 60 minute
# hang in CI is its own outage.
$holdSeconds = 0
if ($env:PACKER_SYSPREP_HOLD_ON_ERROR_SECONDS -match '^\d+$') {
    $holdSeconds = [int]$env:PACKER_SYSPREP_HOLD_ON_ERROR_SECONDS
}

function Test-QemuPlatform {
    <#
        Explicit platform assertion. Throws when the guest is clearly not the
        Proxmox/QEMU/KVM platform this repository builds for, most importantly
        when it looks like VMware.
    #>
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop

    $markers = @(
        $bios.Manufacturer,
        $bios.SMBIOSBIOSVersion,
        $system.Manufacturer,
        $system.Model,
        $product.Vendor,
        $product.Name
    ) -join " | "

    Write-Host "Platform markers: $markers"

    foreach ($vmware in @("VMware", "VMW")) {
        if ($markers -like "*$vmware*") {
            throw "This guest reports VMware platform markers ($markers). This repository builds Proxmox/QEMU templates; refusing to generalize an image on an unexpected platform."
        }
    }

    $qemuMatched = $false
    foreach ($keyword in @("QEMU", "KVM", "Bochs", "SeaBIOS", "Proxmox", "OVMF", "EFI Development Kit")) {
        if ($markers -like "*$keyword*") {
            $qemuMatched = $true
            break
        }
    }

    if (-not $qemuMatched) {
        throw "No QEMU/KVM platform markers found ($markers). Refusing to generalize. Set PACKER_SYSPREP_ALLOW_UNKNOWN_PLATFORM=1 if this really is the intended hypervisor."
    }
}

function Get-UnattendPath {
    [CmdletBinding()]
    param([string]$Requested, [string[]]$Candidates)

    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) {
            throw "Unattend file '$Requested' does not exist. Sysprep /generalize /oobe without an answer file produces a template whose clones hang at the interactive OOBE wizard and never reach WinRM."
        }
        return (Resolve-Path -LiteralPath $Requested).Path
    }

    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Write-Host "Using discovered unattend file: $candidate"
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw ("No sysprep answer file supplied and none found at: {0}. " -f ($Candidates -join ", ")) +
    "Refusing to run /generalize /oobe without /unattend: - the resulting template's clones halt at the interactive OOBE wizard, never start WinRM, and look like dead VMs to Packer and Ansible. " +
    "Pass -UnattendPath, set PACKER_SYSPREP_UNATTEND, or drop an unattend.xml at one of the probed locations."
}

function Test-SetupErrLog {
    <#
        Sysprep can exit 0 and still have logged fatal errors. Anything written
        to setuperr.log during this run is treated as a failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LogPath, [Parameter(Mandatory = $true)][datetime]$Since)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        Write-Host "No setuperr.log at $LogPath (nothing logged)."
        return
    }

    $log = Get-Item -LiteralPath $LogPath
    if ($log.LastWriteTime -lt $Since) {
        Write-Host "setuperr.log untouched by this run (last written $($log.LastWriteTime))."
        return
    }

    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop | Where-Object { "$_".Trim().Length -gt 0 })
    if ($lines.Count -eq 0) {
        Write-Host "setuperr.log was touched but is empty."
        return
    }

    Write-Host "setuperr.log contents ($($lines.Count) line(s)):"
    foreach ($line in $lines) {
        Write-Host "  $line"
    }

    throw "Sysprep wrote $($lines.Count) error line(s) to $LogPath during this run; the image is NOT safely generalized."
}

function Test-UnattendContent {
    <#
        Well-formed XML is not the same as a usable sysprep answer file. An
        Autounattend.xml that only answers the windowsPE pass parses perfectly
        and still leaves every clone sitting at the OOBE wizard - which is the
        precise outcome this script exists to prevent. Assert the structure, and
        say plainly which passes were found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][xml]$Document, [Parameter(Mandatory = $true)][string]$Path)

    if (-not $Document.DocumentElement -or $Document.DocumentElement.LocalName -ne 'unattend') {
        throw "Unattend file '$Path' is valid XML but its root element is '$($Document.DocumentElement.LocalName)', not <unattend>. This is not a Windows answer file."
    }

    $passes = @(@($Document.DocumentElement.ChildNodes) |
        Where-Object { $_.LocalName -eq 'settings' } |
        ForEach-Object { "$($_.pass)" } |
        Where-Object { $_ })

    if ($passes.Count -eq 0) {
        throw "Unattend file '$Path' contains no <settings pass=...> sections, so sysprep would have nothing to apply and clones would halt at the interactive OOBE wizard."
    }

    Write-Host "Unattend passes present: $($passes -join ', ')"

    if ($passes -notcontains 'oobeSystem') {
        Write-Host "*******************************************************************"
        Write-Host "WARNING: '$Path' has no oobeSystem pass."
        Write-Host "WARNING: the oobeSystem pass is what answers the out-of-box wizard."
        Write-Host "WARNING: without it a clone can still stop at OOBE and never reach"
        Write-Host "WARNING: WinRM. Continuing because a specialize-only answer file is"
        Write-Host "WARNING: legitimate in some flows, but VERIFY A CLONE BOOTS before"
        Write-Host "WARNING: trusting this template."
        Write-Host "*******************************************************************"
    }
}

function Test-GeneralizedState {
    <#
        Verify the effect rather than trusting the exit code: after a
        successful /generalize the setup status registry must say so.

        Retried briefly: sysprep.exe /quit has been seen to return a moment
        before the status keys settle, and a single read then produces a
        spurious failure. The loop only tolerates lateness, never absence - it
        still throws once the attempts run out.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 60)

    $statusKey = "HKLM:\SYSTEM\Setup\Status"
    $sysprepKey = "HKLM:\SYSTEM\Setup\Status\SysprepStatus"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    $imageState = $null
    $generalizationState = $null

    do {
        $imageState = $null
        $generalizationState = $null

        if (Test-Path -LiteralPath $statusKey) {
            $imageState = (Get-ItemProperty -Path $statusKey -Name "ImageState" -ErrorAction SilentlyContinue).ImageState
        }
        if (Test-Path -LiteralPath $sysprepKey) {
            $generalizationState = (Get-ItemProperty -Path $sysprepKey -Name "GeneralizationState" -ErrorAction SilentlyContinue).GeneralizationState
        }

        Write-Host "ImageState: $imageState / GeneralizationState: $generalizationState"

        if ("$imageState" -like "*GENERALIZE*" -or "$generalizationState" -eq "7") {
            Write-Host "Verified: the image reports a generalized state."
            return
        }

        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $deadline)

    throw "Sysprep reported success but the image does not report a generalized state after $TimeoutSeconds seconds (ImageState='$imageState', GeneralizationState='$generalizationState'). Refusing to call this a template."
}

$transcriptStarted = $false

try {
    New-Item -Path "C:\Install" -ItemType Directory -Force | Out-Null
    Start-Transcript -Path "C:\Install\999-sysprep.txt" -Append
    $transcriptStarted = $true

    Write-Host "WARNING: sysprep will break WinRM. Nothing can run after this script."

    if ($env:PACKER_SYSPREP_ALLOW_UNKNOWN_PLATFORM -match '^(1|true|yes)$') {
        Write-Host "*******************************************************************"
        Write-Host "WARNING: PACKER_SYSPREP_ALLOW_UNKNOWN_PLATFORM is set."
        Write-Host "WARNING: SKIPPING the hypervisor platform assertion. This image will"
        Write-Host "WARNING: be generalized without confirming it is a Proxmox/QEMU guest."
        Write-Host "*******************************************************************"
    }
    else {
        Test-QemuPlatform
    }

    if (-not (Test-Path -LiteralPath $sysprepExe)) {
        throw "Sysprep.exe not found at $sysprepExe"
    }

    $answerFile = Get-UnattendPath -Requested $UnattendPath -Candidates $unattendCandidates

    # Fail on a malformed answer file here rather than discovering it as a
    # hung clone an hour later.
    $answerXml = $null
    try {
        $answerXml = [xml](Get-Content -LiteralPath $answerFile -Raw)
    }
    catch {
        throw "Unattend file '$answerFile' is not valid XML: $($_.Exception.Message)"
    }
    Write-Host "Sysprep answer file: $answerFile"
    Test-UnattendContent -Document $answerXml -Path $answerFile

    $runStart = Get-Date
    Write-Host "Running Sysprep /oobe /generalize /quiet /quit /unattend:$answerFile"
    & $sysprepExe /oobe /generalize /quiet /quit "/unattend:$answerFile"
    $sysprepExit = $LASTEXITCODE

    # Native commands do not throw; the exit code is the only signal.
    if ($sysprepExit -ne 0) {
        throw "Sysprep.exe exited with code $sysprepExit. See $setupErrLog and $sysprepDir\Panther\setupact.log."
    }

    Test-SetupErrLog -LogPath $setupErrLog -Since $runStart
    Test-GeneralizedState

    Write-Host "Sysprep completed successfully and the generalized state was verified."
}
catch {
    Write-Host "Sysprep failed:"
    Write-Host $_.Exception.Message
    Write-Host $_.ScriptStackTrace

    if ($holdSeconds -gt 0) {
        Write-Host "PACKER_SYSPREP_HOLD_ON_ERROR_SECONDS=$holdSeconds - holding the VM open for inspection."
        Start-Sleep -Seconds $holdSeconds
    }

    # The finally block below closes the transcript before this exit takes
    # effect; failure is reported as a non-zero exit, never swallowed.
    exit 1
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Host "Stop-Transcript: $($_.Exception.Message)"
        }
    }
}

exit 0
