###############################################################################
# Name:             54-install-ps7.ps1
# Description:      Installs PowerShell 7 by downloading Microsoft's
#                   install-powershell.ps1 bootstrap and running it with
#                   -UseMSI -Quiet, then proves the install by executing
#                   %ProgramFiles%\PowerShell\7\pwsh.exe and checking that
#                   it reports a 7.x version.
# Author:           Daniel Whicker
# Date:             2021-09-08
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\54-install-ps7.txt.
#   2. Removes any stale C:/Install/install-powershell.ps1, then downloads
#      the bootstrap script from PS7_INSTALLER_URL (default
#      https://aka.ms/install-powershell.ps1) with a 300s timeout.
#   3. Sanity-checks the payload and, when a pin is supplied, checksums it.
#   4. Primes $LASTEXITCODE with `cmd /c exit 0` so a stale value from an
#      earlier command cannot be misread as the installer's, then runs the
#      bootstrap with -UseMSI -Quiet.
#   5. Verifies the resulting pwsh.exe by running it.
#
# WHAT IT VERIFIES
#   - The downloaded file exists, is at least 1KB, does not start with '<'
#     (an HTML error page), and mentions "powershell". This file is EXECUTED
#     as PowerShell, so size alone would not be enough.
#   - When PS7_INSTALLER_SHA256 is set it must be 64 hex characters and must
#     match the downloaded file.
#   - The bootstrap is a .ps1 and sets no exit code of its own, so
#     $LASTEXITCODE afterwards is msiexec's: 0 and 3010 (reboot required) are
#     accepted, anything else is fatal.
#   - That the install landed: %ProgramFiles%\PowerShell\7\pwsh.exe exists,
#     runs ($PSVersionTable.PSVersion via -NoProfile -c, exit code 0),
#     returns a non-empty version, and that version starts with "7.". An
#     msiexec exit code of 0 is explicitly not treated as the evidence.
#
# FAILURE CONTRACT
#   FATAL     : the download is missing, too small, HTML, or unrecognised; a
#               malformed or mismatched PS7_INSTALLER_SHA256; an installer
#               exit code outside {0,3010}; pwsh.exe missing; pwsh.exe present
#               but failing to run, reporting nothing, or reporting a non-7.x
#               version.
#   LOUD SKIP : none. PS7_INSTALLER_SHA256 being unset prints a WARNING
#               banner - including the observed SHA256 so it can be pinned -
#               and then CONTINUES; it does not exit.
#
# INPUTS (environment)
#   PS7_INSTALLER_URL      bootstrap script URL; defaults to
#                          https://aka.ms/install-powershell.ps1 when unset.
#   PS7_INSTALLER_SHA256   optional SHA256 pin for that script. aka.ms serves
#                          a moving target, so it cannot be hardcoded here;
#                          unset means the build executes unverified remote
#                          code and says so loudly.
#   PACKER_DEBUG_HOLD      when set, sleeps 3600s on failure so the transcript
#                          can be read before Packer destroys the VM. Unset by
#                          default.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. No *.pkr.hcl in this repo references this
#     script; it is a library script.
#   - History: the previous version was a three-line download-and-execute -
#     no error preference, no try/catch, no transcript teardown, no integrity
#     check, no exit code check and no post-install assertion. A network
#     hiccup, a 404 returning an HTML error page, or an msiexec failure all
#     produced a "successful" build with no PowerShell 7 on the template.
#   - C:/Install is created here because this script is not guaranteed to run
#     after one that creates it, and it both transcribes and downloads into
#     it; without that, Start-Transcript throws before the try/catch is even
#     in scope.
#   - $PSNativeCommandUseErrorActionPreference is disabled so PowerShell 7.4+
#     does not turn a non-zero native exit (including the legitimate 3010)
#     into a terminating error. No-op on Windows PowerShell 5.1.
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

# PowerShell 7.4+ turns a non-zero NATIVE exit code into a terminating error
# while $ErrorActionPreference is 'Stop', which would bypass the explicit
# $LASTEXITCODE checks below (including the legitimate 3010). Harmless no-op on
# Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# This script is not guaranteed to run after one that creates C:/Install, and it
# both transcribes and downloads into it. Without this, Start-Transcript throws
# before the try/catch is even in scope.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/54-install-ps7.txt' -Append

try {
    Write-Host "Installing PowerShell 7"

    $url = if ([string]::IsNullOrWhiteSpace($env:PS7_INSTALLER_URL)) {
        "https://aka.ms/install-powershell.ps1"
    }
    else {
        $env:PS7_INSTALLER_URL
    }
    $outputPath = "C:/Install/install-powershell.ps1"

    Write-Host "Downloading installer script from $url"
    # Never reuse a leftover file from an earlier run, and never let a download
    # hang the build with no timeout.
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    Invoke-WebRequest -Uri $url -OutFile $outputPath -UseBasicParsing -TimeoutSec 300

    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "Download reported success but $outputPath does not exist"
    }
    $size = (Get-Item -LiteralPath $outputPath).Length
    if ($size -lt 1KB) {
        throw "Downloaded $outputPath is only $size bytes - that is not the install-powershell bootstrap script"
    }

    # Size alone proves nothing: a proxy/captive-portal error page is easily
    # larger than 1 KB, and this file gets EXECUTED as PowerShell below.
    $content = Get-Content -LiteralPath $outputPath -Raw
    if ($content.TrimStart().StartsWith('<')) {
        throw "Downloaded $outputPath starts with '<' - that is an HTML error page, not PowerShell; refusing to execute it"
    }
    if ($content -notmatch '(?i)powershell') {
        throw "Downloaded $outputPath never mentions 'powershell' - refusing to execute an unrecognised payload from $url"
    }

    Write-Host "Downloaded $outputPath ($size bytes)"

    $actualHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLower()
    if ([string]::IsNullOrWhiteSpace($env:PS7_INSTALLER_SHA256)) {
        Write-Host "*******************************************************************"
        Write-Host "WARNING: PS7_INSTALLER_SHA256 is not set, so this build is executing"
        Write-Host "WARNING: UNVERIFIED remote code from $url"
        Write-Host "WARNING: observed SHA256 = $actualHash"
        Write-Host "WARNING: pin it by setting PS7_INSTALLER_SHA256 in the build env."
        Write-Host "*******************************************************************"
    }
    else {
        $expectedHash = $env:PS7_INSTALLER_SHA256.Trim().ToLower()
        if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
            throw "PS7_INSTALLER_SHA256 ('$expectedHash') is not a 64-character hex SHA256"
        }
        if ($actualHash -ne $expectedHash) {
            throw "PowerShell 7 installer script checksum mismatch: expected $expectedHash, got $actualHash"
        }
        Write-Host "Checksum OK (SHA256)"
    }

    # The bootstrap script shells out to msiexec. It is a .ps1, so it does not
    # set an exit code of its own; $LASTEXITCODE afterwards is msiexec's.
    Write-Host "Running the PowerShell 7 MSI installer"
    & cmd.exe /c "exit 0"   # prime $LASTEXITCODE so a stale value cannot be misread
    & $outputPath -UseMSI -Quiet
    $installerExit = $LASTEXITCODE
    Write-Host "Installer exit code: $installerExit"
    if ($null -ne $installerExit -and $installerExit -ne 0 -and $installerExit -ne 3010) {
        # 3010 = success, reboot required
        throw "PowerShell 7 installer failed with exit code $installerExit"
    }

    # --- verify -------------------------------------------------------------
    # The exit code is not the evidence; a working pwsh.exe is.
    # Derived from the environment rather than hardcoded to C:, so the check
    # still points at the real install location on an image whose Program Files
    # is not on C:. The MSI's own default is <ProgramFiles>\PowerShell\7.
    $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath)) {
        throw "Installer reported success but $pwshPath does not exist"
    }

    $version = & $pwshPath -NoProfile -c '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0) {
        throw "$pwshPath exists but failed to run (exit code $LASTEXITCODE)"
    }
    $version = ($version | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "$pwshPath ran but reported no version"
    }
    if ($version -notmatch '^7\.') {
        throw "$pwshPath reported version '$version', expected 7.x"
    }
    Write-Host "Verified: $pwshPath runs and reports PowerShell $version"

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
