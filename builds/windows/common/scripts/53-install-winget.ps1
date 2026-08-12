###############################################################################
# Name:             53-install-winget.ps1
# Description:      Provisions winget per-machine (the App Installer msixbundle
#                   plus its VCLibs dependency), proves a real winget.exe
#                   exists and runs, then installs eleven applications with it
#                   and confirms each one with `winget list`.
# Author:           Daniel Whicker
# Date:             2021-10-28
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\53-install-winget.txt.
#   2. Looks for an existing winget.exe (see WHAT IT VERIFIES for how) and
#      skips provisioning when it finds one.
#   3. Otherwise forces TLS 1.2 and, in this order, downloads and provisions
#      Microsoft.VCLibs.140.00.UWPDesktop (aka.ms appx) and then
#      Microsoft.DesktopAppInstaller (the winget-cli latest msixbundle from
#      GitHub), each with Add-AppxProvisionedPackage -Online -SkipLicense.
#      Provisioning errors are recorded rather than swallowed, and are
#      reprinted only if the assertion in step 4 fails.
#   4. Asserts winget.exe is now resolvable, then runs `winget --version`.
#   5. Installs each id with `winget install --id <id> --exact --silent
#      --accept-package-agreements --accept-source-agreements
#      --disable-interactivity`: 7zip.7zip, Git.Git, Google.Chrome,
#      JAMSoftware.TreeSize.Free, Microsoft.RemoteDesktopConnectionManager,
#      Microsoft.Sysinternals.BGInfo, Microsoft.Sysinternals.ProcessExplorer,
#      Microsoft.VisualStudioCode, Microsoft.WindowsTerminal, Mozilla.Firefox,
#      Notepad++.Notepad++.
#   6. Aggregates every failure and reports them together at the end.
#
# WHAT IT VERIFIES
#   - Each download exists, meets a minimum size (100KB for VCLibs, 1MB for
#     the bundle) and starts with the 'PK' ZIP header. appx/msix/msixbundle
#     are ZIP containers, so without the header check a large HTML error page
#     would be handed straight to the provisioner.
#   - winget.exe is resolved from the real payload directory under
#     %ProgramFiles%\WindowsApps, matching
#     Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe, highest version
#     first. The Get-Command fallback REJECTS a zero-byte hit: what PATH
#     usually finds is the AppExecutionAlias reparse stub in
#     %LOCALAPPDATA%\Microsoft\WindowsApps, which does not execute in a
#     non-interactive Packer session and would fail confusingly later.
#   - `winget --version` exits 0 before the binary is trusted with a package
#     list.
#   - Per package: the install exit code is acceptable AND
#     `winget list --id <id> --exact` exits 0 - it exits non-zero when nothing
#     matches, which is what catches an install that reported success and
#     landed nothing.
#
# FAILURE CONTRACT
#   LOUD SKIP : Server Core. It has no Appx servicing stack, so
#               Add-AppxProvisionedPackage fails with "The specified module
#               could not be found" regardless of how the payload is fetched.
#               The script prints a banner saying NO winget and NO packages
#               were installed, and exits 0. Failing here would discard a
#               fully patched template over a Desktop Experience component the
#               platform cannot host - and the package list is GUI software a
#               Core install could not display in any case.
#   FATAL     : a payload download is missing, under its minimum size, or not
#               a 'PK' container; winget.exe cannot be found after
#               provisioning (the error reprints any provisioning errors plus
#               the platform explanation below); `winget --version` exits
#               non-zero; any package fails its install exit code or its
#               `winget list` check. Accepted install exit codes are 0, 3010
#               (reboot required), -1978335189 (0x8A15002B, no applicable
#               update) and -1978335135 (0x8A150061, already installed).
#   LOUD SKIP : none. Provisioning errors on their own are non-fatal and are
#               logged as a NOTE, but only when winget.exe still resolves
#               afterwards.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   when set, sleeps 3600s on failure so the transcript
#                       can be read before Packer destroys the VM. Unset by
#                       default.
#
# NOTES
#   - WIRED IN: this is the only script in the 40-70 range that any build
#     references. It runs in all four ISO builds (Server 2022 and 2025, Core
#     and Desktop Experience) and in common/cloud-clone-build.pkr.hcl. Note
#     that the package list is GUI software and is installed on Core too.
#   - KNOWN PLATFORM LIMITATION (documented, not a config bug):
#     Add-AppxPackage FAILS inside a Packer provisioner session with HRESULT
#     0x80073D19 ("a user was logged off") - the remote/scheduled-task session
#     has no interactive user token to deploy a per-user Appx into. This
#     script therefore uses Add-AppxProvisionedPackage -Online, which is
#     per-machine and needs no interactive user, and fails loudly if
#     winget.exe still cannot be located afterwards.
#   - Server 2022 may also lack the Microsoft.WindowsAppRuntime framework
#     that newer App Installer bundles bind to. If winget still cannot be
#     resolved there, it is not obtainable on that image from a Packer session
#     and this script must be dropped from the builds that reference it, or
#     winget installed by hand on a clone.
#   - The cloud-clone build used to omit this script for exactly that reason;
#     it runs it again now that provisioning is per-machine and asserted.
#   - $PSNativeCommandUseErrorActionPreference is disabled so PowerShell 7.4+
#     does not turn a non-zero native exit into a terminating error and bypass
#     the explicit $LASTEXITCODE checks. No-op on Windows PowerShell 5.1.
###############################################################################

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# PowerShell 7.4+ turns a non-zero NATIVE exit code into a terminating error
# while $ErrorActionPreference is 'Stop', which would bypass the explicit
# $LASTEXITCODE checks below. Harmless no-op on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

$WingetPackages = @(
    '7zip.7zip',
    'Git.Git',
    'Google.Chrome',
    'JAMSoftware.TreeSize.Free',
    'Microsoft.RemoteDesktopConnectionManager',
    'Microsoft.Sysinternals.BGInfo',
    'Microsoft.Sysinternals.ProcessExplorer',
    'Microsoft.VisualStudioCode',
    'Microsoft.WindowsTerminal',
    'Mozilla.Firefox',
    'Notepad++.Notepad++'
)

# Dependencies must be provisioned before the App Installer bundle itself.
$WingetPayload = @(
    @{
        name    = 'Microsoft.VCLibs.140.00.UWPDesktop'
        url     = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
        file    = 'C:\Install\Microsoft.VCLibs.x64.14.00.Desktop.appx'
        minSize = 100KB
    },
    @{
        name    = 'Microsoft.DesktopAppInstaller'
        url     = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        file    = 'C:\Install\Microsoft.DesktopAppInstaller.msixbundle'
        minSize = 1MB
    }
)

# winget exit codes that are not failures:
#   0           success
#   3010        success, reboot required
#   -1978335189 0x8A15002B no applicable update
#   -1978335135 0x8A150061 package already installed
$AcceptableExitCodes = @(0, 3010, -1978335189, -1978335135)

$AppxFailureExplanation = @'
winget.exe could not be found after provisioning the App Installer package.
This is the documented Packer/Appx limitation: Add-AppxPackage cannot deploy
from a Packer provisioner session (HRESULT 0x80073D19 "a user was logged off")
and Server 2022 has no Microsoft.WindowsAppRuntime framework for newer App
Installer builds. Provisioning per-machine is the workaround this script uses;
if it still fails, winget is not obtainable on this image from a Packer session
and this script must be dropped from the build definitions that reference it,
or winget installed by hand on a clone.
'@

###############################################################################
# Functions
###############################################################################

function Get-WingetPath {
    # Resolve the REAL payload first. What Get-Command finds on PATH is usually
    # the zero-byte AppExecutionAlias in %LOCALAPPDATA%\Microsoft\WindowsApps,
    # which is a reparse stub that does not execute in a non-interactive Packer
    # session - trusting it produces a confusing failure later.
    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    $packageDirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory `
            -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending)

    foreach ($dir in $packageDirs) {
        $candidate = Join-Path $dir.FullName 'winget.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) {
        $length = (Get-Item -LiteralPath $command.Source -ErrorAction SilentlyContinue).Length
        if ($length -gt 0) {
            return $command.Source
        }
        Write-Host "Ignoring $($command.Source): it is a zero-byte AppExecutionAlias stub, not a runnable winget.exe"
    }

    return $null
}

function Get-AppxPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Payload)

    if (Test-Path -LiteralPath $Payload.file) {
        Remove-Item -LiteralPath $Payload.file -Force
    }

    Write-Host "Downloading $($Payload.name) from $($Payload.url)"
    # Limited egress: never let a download hang the build.
    Invoke-WebRequest -Uri $Payload.url -OutFile $Payload.file -UseBasicParsing -TimeoutSec 600

    if (-not (Test-Path -LiteralPath $Payload.file)) {
        throw "Download of $($Payload.name) reported success but $($Payload.file) does not exist."
    }

    $size = (Get-Item -LiteralPath $Payload.file).Length
    if ($size -lt $Payload.minSize) {
        throw "Download of $($Payload.name) is only $size bytes (expected at least $($Payload.minSize)); this is almost certainly an error page, not a package."
    }

    # appx/msix/msixbundle are ZIP containers: they start with 'PK'. An HTML
    # error page or a redirect landing page big enough to pass the size check
    # would otherwise be handed to Add-AppxProvisionedPackage.
    $stream = [System.IO.File]::OpenRead($Payload.file)
    try {
        $buffer = New-Object byte[] 2
        $read = $stream.Read($buffer, 0, 2)
        $magic = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    }
    finally {
        $stream.Dispose()
    }
    if ($magic -ne 'PK') {
        throw "Download of $($Payload.name) does not start with the 'PK' ZIP header (got '$magic'); it is not an appx/msix package - refusing to provision it."
    }

    Write-Host "Downloaded $($Payload.name) ($size bytes)"
}

function Test-AppxServicingAvailable {
    # Server Core ships without the Appx servicing stack, so
    # Add-AppxProvisionedPackage fails there with "The specified module could
    # not be found" no matter how the payload is fetched. That is a platform
    # boundary, not a bug to work around: winget is a Desktop Experience
    # component and the packages it would install here are GUI applications
    # that a Core install has no way to display.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $installationType = $null
    try {
        $installationType = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -Name 'InstallationType' -ErrorAction Stop).InstallationType
    }
    catch {
        Write-Host "Could not read InstallationType ($($_.Exception.Message)); assuming Appx is available."
        return $true
    }

    Write-Host "Windows InstallationType: $installationType"
    if ($installationType -eq 'Server Core') { return $false }

    # Belt and braces: even on a full Server install, the cmdlet has to exist.
    if (-not (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        Write-Host "Add-AppxProvisionedPackage is not available on this image."
        return $false
    }
    return $true
}

function Install-Winget {
    $existing = Get-WingetPath
    if ($existing) {
        Write-Host "winget is already present at $existing"
        return $existing
    }

    Write-Host "winget is not installed. Provisioning the App Installer package."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Provisioning errors are recorded, not swallowed: a dependency that is
    # already present on the image can throw while winget still ends up usable.
    # Nothing here is treated as success - the assertion below is the only gate,
    # and every recorded error is reprinted if it fails.
    $provisionErrors = New-Object System.Collections.Generic.List[string]

    foreach ($payload in $WingetPayload) {
        Get-AppxPayload -Payload $payload

        Write-Host "Provisioning $($payload.name)"
        try {
            # Add-AppxProvisionedPackage, NOT Add-AppxPackage - see the header.
            Add-AppxProvisionedPackage -Online -PackagePath $payload.file -SkipLicense | Out-Null
            Write-Host "Provisioned $($payload.name)"
        }
        catch {
            $message = "Add-AppxProvisionedPackage failed for $($payload.name): $($_.Exception.Message)"
            Write-Host "WARNING: $message"
            $provisionErrors.Add($message)
        }
    }

    # Hard post-install assertion. An installer returning without error is not
    # evidence that anything landed.
    $wingetPath = Get-WingetPath
    if ($null -eq $wingetPath) {
        $detail = if ($provisionErrors.Count -gt 0) {
            "Provisioning errors seen along the way:`n  - " + ($provisionErrors -join "`n  - ") + "`n"
        }
        else {
            "Add-AppxProvisionedPackage reported no error, so this is a silent no-op.`n"
        }
        throw "$detail$AppxFailureExplanation"
    }

    if ($provisionErrors.Count -gt 0) {
        Write-Host "NOTE: winget resolved despite $($provisionErrors.Count) provisioning error(s) above; they were non-fatal."
    }

    Write-Host "Verified winget is present at $wingetPath"
    return $wingetPath
}

###############################################################################
# Main
###############################################################################

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/53-install-winget.txt' -Append

try {
    # LOUD SKIP on Server Core. Not a silent no-op: the banner states plainly
    # that no packages were installed, so a transcript can never be misread as
    # "winget configured". Failing the build instead would throw away a fully
    # patched template over a component the platform cannot host.
    if (-not (Test-AppxServicingAvailable)) {
        Write-Host ""
        Write-Host "*******************************************************************"
        Write-Host "*** SKIPPED: winget is NOT available on this image"
        Write-Host "***"
        Write-Host "*** Server Core has no Appx servicing stack, so"
        Write-Host "*** Add-AppxProvisionedPackage cannot deploy the App Installer"
        Write-Host "*** bundle. NO winget and NO packages were installed."
        Write-Host "***"
        Write-Host "*** This is a platform boundary, not a build failure: winget is a"
        Write-Host "*** Desktop Experience component, and the package list here is GUI"
        Write-Host "*** software a Core install could not display anyway."
        Write-Host "*******************************************************************"
        Write-Host ""
        exit 0
    }

    $winget = Install-Winget

    # Prove the binary actually runs before trusting it with a package list.
    & $winget --version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$winget exists but 'winget --version' exited $LASTEXITCODE."
    }

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($packageId in $WingetPackages) {
        Write-Host "Installing $packageId"
        & $winget install --id $packageId --exact --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity

        if ($AcceptableExitCodes -notcontains $LASTEXITCODE) {
            $failures.Add("$packageId (winget exit code $LASTEXITCODE)")
            continue
        }

        # Verify the effect: 'winget list' exits non-zero when nothing matches.
        & $winget list --id $packageId --exact --disable-interactivity --accept-source-agreements | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("$packageId (install exited 0 but 'winget list' cannot find it)")
            continue
        }

        Write-Host "Verified $packageId is installed"
    }

    if ($failures.Count -gt 0) {
        throw "$($failures.Count) of $($WingetPackages.Count) winget packages failed: $($failures -join '; ')"
    }

    Write-Host "All $($WingetPackages.Count) winget packages installed and verified."
    exit 0
}
catch {
    Write-Host "Something went wrong: $($_.Exception.Message)"

    # Optional debug hold: set PACKER_DEBUG_HOLD=1 to keep the VM alive for an
    # hour so the error can be inspected before Packer destroys it.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600 seconds before failing."
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
