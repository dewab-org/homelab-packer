###############################################################################
# Name:             71-windows-subsys-linux-part2.ps1
# Description:      Install the WSL2 kernel update, make WSL2 the default
#                   version, and provision Ubuntu 22.04 machine-wide. Runs
#                   after the reboot that part 1 requires.
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################
#
# WHAT IT DOES
#   1. Sets WSL_UTF8=1 and disables PSNativeCommandUseErrorActionPreference,
#      creates C:\Install and starts the transcript.
#   2. Asserts wsl.exe exists - i.e. that part 1 ran AND the VM rebooted.
#   3. Downloads the WSL2 kernel MSI and installs it with msiexec /qn
#      /norestart, logging to C:\Install\wsl_update_x64-msi.log.
#   4. Asserts the kernel landed at %SystemRoot%\System32\lxss\tools\kernel.
#   5. Runs `wsl --set-default-version 2` and reads the setting back.
#   6. Prints `wsl --status` for the transcript (informational, isolated).
#   7. Downloads the Ubuntu 22.04 appx, snapshots which Ubuntu packages are
#      already provisioned, then provisions it MACHINE-WIDE with
#      Add-AppxProvisionedPackage -Online -SkipLicense.
#   8. Re-queries the provisioned packages and prints `wsl -l -v`.
#
# WHAT IT VERIFIES
#   - wsl.exe is present. Failure means part 1 did not run or the VM was not
#     rebooted; said plainly instead of a cryptic CommandNotFoundException.
#   - Every download: file exists, meets a minimum size, AND begins with the
#     right magic bytes - D0 CF 11 E0 (OLE2) for the MSI, 50 4B ("PK") for the
#     appx. Size alone is not evidence; an HTML error page large enough to pass
#     a size check would otherwise be handed to msiexec or Appx provisioning.
#   - msiexec's exit code (0 or 3010 only) AND the kernel file on disk.
#   - The Lxss DefaultVersion registry value, not just wsl.exe's exit code.
#   - At least one Ubuntu package is provisioned ON THE IMAGE afterwards. The
#     before/after snapshot also distinguishes "we provisioned it" from "it was
#     already there", so a re-run cannot be reported as a fresh install.
#
# FAILURE CONTRACT
#   FATAL     : wsl.exe absent; a download that fails, is too small, or has the
#               wrong header; msiexec exiting anything but 0/3010; the kernel
#               file missing after install; `wsl --set-default-version 2`
#               returning non-zero or the registry value not reading back as 2;
#               no Ubuntu package provisioned after the add. Each exits 1.
#   LOUD SKIP : none - this script has no path that exits 0 early. Two
#               non-fatal conditions are reported instead of hidden: an
#               unreadable `wsl --status` / `wsl -l -v` prints a WARNING (both
#               calls are purely informational and isolated because merging a
#               native command's stderr can raise NativeCommandError under
#               $ErrorActionPreference='Stop'), and an image that already had
#               Ubuntu provisioned prints a NOTE naming the pre-existing
#               package.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   Optional. On failure, sleep 3600s before exiting so the
#                       VM can be inspected before Packer destroys it.
#
# NOTES
#   - Prerequisite: the Microsoft-Windows-Subsystem-Linux and
#     VirtualMachinePlatform features from part 1 must be enabled and the VM
#     rebooted before this runs.
#   - MACHINE-WIDE PROVISIONING IS THE FIX. The distro used to be installed
#     with Add-AppxPackage, which is PER USER - only for the disposable Packer
#     build account, later expired/renamed - so no clone user ever had Ubuntu.
#   - KNOWN PER-USER LIMITATION, deliberately not worked around: the WSL
#     default version lives in HKCU\Software\Microsoft\Windows\CurrentVersion\
#     Lxss\DefaultVersion, so setting it here only affects the build account
#     and new users on a clone get the OS default. Writing it into the default
#     profile hive was judged too invasive for a value WSL rewrites on first
#     use; run `wsl --set-default-version 2` per user or handle it in the
#     golden image's first-logon automation.
#   - `wsl -l -v` may legitimately list nothing: a provisioned distro is not
#     registered until a user launches it. That is why the output is printed
#     rather than asserted - asserting it would be a false negative.
#   - wsl.exe writes UTF-16LE by default, which turns every string comparison
#     into a coin flip; WSL_UTF8=1 makes its output plain UTF-8.
#   - Historical silent no-ops fixed here: the MSI was launched via the shell's
#     "open" verb (so MSI switches never reached msiexec) with no -Wait and no
#     exit code check; `wsl --set-default-version 2` is native and its non-zero
#     exit was ignored; neither download had a timeout (a stalled fetch hung
#     the build forever) or a content check; C:\Install was never created, so
#     Start-Transcript blew up before the try/catch was in scope. The URL is
#     and always was 22.04, whatever the old comment claimed.

###############################################################################
# Variables
###############################################################################

$distribution_url = "https://aka.ms/wslubuntu2204" # Ubuntu 22.04 LTS
$kernel_url = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
$kernel_msi = "C:\Install\wsl_update_x64.msi"
$distribution_pkg = "C:\Install\Linux.appx"

###############################################################################
# Preferences
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

# PowerShell 7.4+ turns a non-zero NATIVE exit code into a terminating error
# while $ErrorActionPreference is 'Stop', which would bypass the explicit
# $LASTEXITCODE checks below. Harmless no-op on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# wsl.exe writes UTF-16LE by default, which turns every string comparison below
# into a coin flip. WSL_UTF8 makes its output plain UTF-8.
$env:WSL_UTF8 = "1"

# This script is not guaranteed to run after one that creates C:/Install, and it
# both transcribes and downloads into it. Without this, Start-Transcript throws
# before the try/catch is even in scope.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/71-windows-subsys-linux-part2.txt' -Append

###############################################################################
# Functions
###############################################################################

function Get-FileHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Count = 4
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $Count)
        if ($read -lt $Count) {
            throw "Could not read $Count header bytes from ${Path}: only $read bytes available"
        }
        return $buffer
    }
    finally {
        $stream.Dispose()
    }
}

function Save-VerifiedDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][long]$MinimumBytes,
        [Parameter(Mandatory)][byte[]]$ExpectedHeader,
        [Parameter(Mandatory)][string]$HeaderDescription
    )

    # Never reuse a leftover file from an earlier run.
    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }

    # Limited egress: a download must time out rather than hang the build.
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600

    if (-not (Test-Path -LiteralPath $OutFile)) {
        throw "Download of $Description reported success but $OutFile does not exist"
    }

    $size = (Get-Item -LiteralPath $OutFile).Length
    if ($size -lt $MinimumBytes) {
        throw "Download of $Description is only $size bytes (expected at least $MinimumBytes) - almost certainly an error page, not a package"
    }

    # Size alone is not evidence. An HTML error page big enough to pass the size
    # check would otherwise be handed straight to msiexec / Appx provisioning.
    $header = Get-FileHeader -Path $OutFile -Count $ExpectedHeader.Length
    $expectedHex = ($ExpectedHeader | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $actualHex = ($header | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    if ($actualHex -ne $expectedHex) {
        throw "Download of $Description does not begin with the $HeaderDescription header (expected $expectedHex, got $actualHex); refusing to use it"
    }

    Write-Host "Downloaded $Description to $OutFile ($size bytes, $HeaderDescription header OK)"
}

###############################################################################
# Main
###############################################################################

try {
    # wsl.exe only exists once part 1's optional features are enabled AND the VM
    # has rebooted. Say so plainly instead of failing later on a cryptic
    # CommandNotFoundException.
    if ($null -eq (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe is not present. 70-windows-subsys-linux-part1.ps1 must run and the VM must reboot before this script."
    }

    Write-Host "Download Kernel Update for WSL2"
    # An MSI is an OLE2 compound file: D0 CF 11 E0.
    Save-VerifiedDownload -Uri $kernel_url -OutFile $kernel_msi `
        -Description 'WSL2 kernel update MSI' -MinimumBytes 1MB `
        -ExpectedHeader ([byte[]](0xD0, 0xCF, 0x11, 0xE0)) -HeaderDescription 'MSI (OLE2)'

    Write-Host "Installing Kernel Update for WSL2"
    $kernelLog = 'C:\Install\wsl_update_x64-msi.log'
    $msi = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', "`"$kernel_msi`"", '/qn', '/norestart', '/l*v', "`"$kernelLog`"") `
        -Wait -PassThru
    Write-Host "msiexec exit code: $($msi.ExitCode)"
    if ($msi.ExitCode -ne 0 -and $msi.ExitCode -ne 3010) {   # 3010 = success, reboot required
        throw "WSL2 kernel update failed with exit code $($msi.ExitCode); see $kernelLog"
    }

    # Verify the kernel actually landed rather than trusting msiexec.
    # From %SystemRoot%, not hardcoded to C:\Windows.
    $kernelPath = Join-Path $env:SystemRoot 'System32\lxss\tools\kernel'
    if (-not (Test-Path -LiteralPath $kernelPath)) {
        throw "WSL2 kernel update reported success but $kernelPath does not exist"
    }
    Write-Host "Verified: WSL2 kernel present at $kernelPath"

    Write-Host "Enabling WSL Version 2 by Default"
    & wsl.exe --set-default-version 2
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --set-default-version 2 failed with exit code $LASTEXITCODE"
    }

    # Read the setting back. A zero exit code from wsl.exe is not evidence that
    # the default version was actually written. (Per-user by design - see the
    # KNOWN PER-USER LIMITATION note in the header; this only proves it took
    # effect for the build account.)
    $lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $defaultVersion = (Get-ItemProperty -Path $lxssKey -Name 'DefaultVersion' -ErrorAction SilentlyContinue).DefaultVersion
    if ($defaultVersion -ne 2) {
        throw "wsl --set-default-version 2 exited 0 but $lxssKey\DefaultVersion is '$defaultVersion' (expected 2); the setting did not take."
    }
    Write-Host "Verified: $lxssKey\DefaultVersion = $defaultVersion"

    # Informational. Redirecting a native command's stderr while
    # $ErrorActionPreference is 'Stop' can raise NativeCommandError in Windows
    # PowerShell 5.1, so this reporting call is isolated.
    try {
        $status = (& wsl.exe --status 2>&1 | Out-String)
        Write-Host "wsl --status output:"
        Write-Host $status
    }
    catch {
        Write-Host "WARNING: could not read 'wsl --status': $($_.Exception.Message)"
    }

    Write-Host "Downloading Linux Distribution ($distribution_url)"
    # appx/appxbundle are ZIP containers: 'PK' = 50 4B.
    Save-VerifiedDownload -Uri $distribution_url -OutFile $distribution_pkg `
        -Description 'Ubuntu 22.04 distro package' -MinimumBytes 1MB `
        -ExpectedHeader ([byte[]](0x50, 0x4B)) -HeaderDescription 'ZIP/appx (PK)'

    # Machine-wide, not per-user: see the header. -SkipLicense is required for
    # provisioning a Store package outside of an image-servicing context.
    # Snapshot first so a pre-existing Ubuntu provisioning cannot be mistaken
    # for evidence that THIS call did something.
    $before = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*Ubuntu*' } |
        ForEach-Object { $_.PackageName })

    Write-Host "Provisioning Distribution for all users"
    Add-AppxProvisionedPackage -Online -PackagePath $distribution_pkg -SkipLicense | Out-Null

    # Verify the provisioned package is registered on the image.
    $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*Ubuntu*' })
    if ($provisioned.Count -eq 0) {
        throw "Add-AppxProvisionedPackage reported success but no Ubuntu package is provisioned on this image"
    }
    foreach ($pkg in $provisioned) {
        Write-Host "Verified provisioned package: $($pkg.DisplayName) $($pkg.Version) [$($pkg.PackageName)]"
    }

    $added = @($provisioned | Where-Object { $before -notcontains $_.PackageName })
    if ($added.Count -eq 0) {
        # Not fatal - re-running this script on an already-provisioned image is
        # legitimate - but it must never be reported as a fresh install.
        Write-Host "NOTE: no NEW Ubuntu package was added; the image already had $($before -join ', ') provisioned before this run."
    }

    # Informational: the distro is provisioned but not registered until a user
    # launches it, so `wsl -l -v` may legitimately list nothing yet. Printed so
    # the transcript records the state rather than asserting a false negative.
    try {
        $list = (& wsl.exe -l -v 2>&1 | Out-String)
        Write-Host "wsl -l -v output (a distro only appears once a user has launched it):"
        Write-Host $list
    }
    catch {
        Write-Host "WARNING: could not read 'wsl -l -v': $($_.Exception.Message)"
    }

    exit 0
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Opt-in debug hold: set PACKER_DEBUG_HOLD in the build environment to keep
    # the VM alive long enough to read this transcript before Packer destroys it.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set - sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
