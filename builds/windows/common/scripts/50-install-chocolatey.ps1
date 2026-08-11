###############################################################################
# Name:             50-install-chocolatey.ps1
# Description:      Installs Chocolatey by downloading and executing the vendor
#                   bootstrap script, then proves it landed by resolving a real
#                   choco.exe and running `choco --version`. Idempotent no-op
#                   when a working choco.exe is already present.
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\50-install-chocolatey.txt.
#   2. Tests for an already-working Chocolatey and exits 0 if it finds one.
#   3. Forces TLS 1.2 and sets chocolateyUseWindowsCompression=false.
#   4. Up to 5 attempts: removes any stale C:\Windows\Temp\install.ps1,
#      downloads https://community.chocolatey.org/install.ps1 with a 120s
#      timeout, sanity-checks the payload, then executes it with
#      $ErrorActionPreference temporarily relaxed to 'Continue' (the vendor
#      script emits non-terminating errors during a perfectly good install).
#   5. Re-tests after every attempt, sleeping 5s between tries.
#
# WHAT IT VERIFIES
#   - That the install actually landed: choco.exe resolves under
#     $env:ChocolateyInstall (else %ProgramData%\chocolatey) in \bin, or on
#     PATH, AND `choco --version` exits 0. Directory existence and `if ($?)`
#     after the vendor script are both treated as non-evidence.
#   - Before the downloaded payload is executed: the file exists, is at least
#     1024 bytes, does not start with '<' (an HTML/XML error page), and
#     mentions "chocolatey". Without these, a captive-portal or proxy error
#     page would be run as PowerShell.
#
# FAILURE CONTRACT
#   FATAL     : Chocolatey is still not usable after 5 attempts. Failing here
#               is deliberate - continuing silently no-ops the dependent 51
#               and 52 scripts and yields a template that looks green with
#               nothing installed. Per-attempt download and validation errors
#               are caught and retried, so they are not fatal on their own.
#   LOUD SKIP : none. The only exit 0 that installs nothing is the idempotent
#               case where a working choco.exe already exists.
#
# INPUTS (environment)
#   ChocolateyInstall   Chocolatey root override; falls back to
#                       %ProgramData%\chocolatey when unset.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. Chocolatey is deliberately not installed on
#     these templates; no *.pkr.hcl references this script (or 51/52). It is
#     kept as a library script for callers that want it.
#   - SECURITY: the vendor bootstrap payload is UNPINNED - there is no
#     checksum and no signature check, so the build trusts whatever the vendor
#     serves at build time. TLS 1.2 plus the size / not-HTML /
#     mentions-Chocolatey checks are the only integrity controls. Mirror and
#     pin the script if that is not acceptable.
#   - Requires Internet egress to community.chocolatey.org.
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

$bootstrapUrl = 'https://community.chocolatey.org/install.ps1'
$installScript = 'C:\Windows\Temp\install.ps1'
$maxTries = 5

###############################################################################
# Functions
###############################################################################

function Get-ChocolateyExe {
    # Real evidence, not "the directory exists": resolve an actual choco.exe.
    $root = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { Join-Path $env:ProgramData 'chocolatey' }
    $candidate = Join-Path $root 'bin\choco.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $command = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Test-Chocolatey {
    # choco.exe must exist AND actually run. `if ($?)` after the vendor script
    # and Test-Path on a directory are both non-evidence.
    $exe = Get-ChocolateyExe
    if ($null -eq $exe) {
        return $false
    }

    $version = & $exe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Found $exe but 'choco --version' exited $LASTEXITCODE"
        return $false
    }

    Write-Host "Chocolatey $($version -join ' ') is installed at $exe"
    return $true
}

###############################################################################
# Main
###############################################################################

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/50-install-chocolatey.txt' -Append

try {
    if (Test-Chocolatey) {
        Write-Host "Chocolatey is already installed and working; nothing to do."
        exit 0
    }

    Write-Host "Installing Chocolatey"

    # Chocolatey requires modern TLS; older defaults fail during bootstrap.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $env:chocolateyUseWindowsCompression = 'false'

    # Test-Chocolatey runs choco.exe, so it is called exactly once per attempt
    # and its verdict is carried out of the loop rather than re-tested after
    # it - nothing changes state between the two calls.
    $chocolateyReady = $false

    for ($try = 1; $try -le $maxTries; $try++) {
        try {
            Write-Host "Downloading Chocolatey bootstrap script (attempt $try of $maxTries)"
            if (Test-Path -LiteralPath $installScript) {
                Remove-Item -LiteralPath $installScript -Force
            }

            # Limited egress: never let a download hang the build.
            Invoke-WebRequest -Uri $bootstrapUrl -OutFile $installScript -UseBasicParsing -TimeoutSec 120

            if (-not (Test-Path -LiteralPath $installScript)) {
                throw "download reported success but $installScript does not exist"
            }

            $size = (Get-Item -LiteralPath $installScript).Length
            if ($size -lt 1024) {
                throw "bootstrap script is only $size bytes - almost certainly an error page, not the installer"
            }

            # Size alone is not enough: a captive-portal or proxy error page is
            # easily larger than 1 KB and would then be EXECUTED as PowerShell.
            # Prove the payload is the vendor script before running it.
            $content = Get-Content -LiteralPath $installScript -Raw
            if ($content.TrimStart().StartsWith('<')) {
                throw "bootstrap script starts with '<' - that is an HTML/XML error page, not PowerShell; refusing to execute it"
            }
            if ($content -notmatch '(?i)chocolatey') {
                throw "bootstrap script never mentions 'chocolatey' - refusing to execute an unrecognised payload from $bootstrapUrl"
            }

            Write-Host "Running Chocolatey bootstrap script ($size bytes)"
            # The vendor script emits non-terminating errors during a perfectly
            # good install; with EAP=Stop those would abort us. Relax it here
            # only, then prove the outcome below.
            $previousEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $installScript
            }
            finally {
                $ErrorActionPreference = $previousEap
            }
        }
        catch {
            Write-Host "Chocolatey install attempt $try failed: $($_.Exception.Message)"
        }

        if (Test-Chocolatey) {
            $chocolateyReady = $true
            break
        }

        Write-Host "Chocolatey still not usable after attempt $try"
        # Only wait when there is another attempt to wait for.
        if ($try -lt $maxTries) {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $chocolateyReady) {
        throw "Chocolatey failed to install after $maxTries attempts. Failing the build loudly: continuing without Chocolatey silently no-ops 51/52 and produces a template that looks green but has nothing installed."
    }

    Write-Host "Chocolatey installation verified."
    exit 0
}
catch {
    Write-Host "Something went wrong: $($_.Exception.Message)"
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }
    exit 1
}
finally {
    Stop-Transcript
}
