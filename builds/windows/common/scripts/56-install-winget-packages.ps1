###############################################################################
# Name:             56-install-winget-packages.ps1
# Description:      Installs a list of applications with winget and verifies
#                   each one landed. LIBRARY SCRIPT - it cannot run in a Packer
#                   build; see WHERE THIS CAN RUN before wiring it into one.
# Author:           Daniel Whicker
# Date:             2026-08-12
###############################################################################
#
# WHERE THIS CAN RUN
#   In an INTERACTIVE session on a running machine: a console or RDP logon, or
#   anything else with a real user desktop. That is the only context in which
#   winget's install path works.
#
#   NOT in a Packer provisioner, and not over WinRM or a scheduled task. This
#   was established by experiment on a clone, and the way it fails is the
#   reason this script is quarantined here rather than left in the build:
#
#     - 'winget --version' succeeds from a Packer elevated provisioner (in the
#       second logon onwards - see 53-install-winget.ps1), so winget LOOKS
#       usable.
#     - 'winget install' then does nothing at all. Start-Process -Wait
#       -PassThru returns an EMPTY ExitCode with empty stdout AND empty stderr,
#       and the package is verifiably absent afterwards. No error is raised
#       anywhere.
#     - Because the bare call operator never sets $LASTEXITCODE for this
#       MSIX-packaged app, the natural check - 'if ($LASTEXITCODE -ne 0)' -
#       compares against $null and PASSES. A build doing this reports eleven
#       successful installs and produces a template with none of them.
#
#   Software that must be baked into a template therefore needs a direct
#   installer instead: see 55-install-non-choco-software.ps1.
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\56-install-winget-packages.txt.
#   2. Refuses to run unless winget is present AND an interactive session is
#      detected, rather than proceeding into the silent-no-op described above.
#   3. Installs each id with 'winget install --id <id> --exact --silent
#      --accept-package-agreements --accept-source-agreements
#      --disable-interactivity'.
#   4. Confirms each install with 'winget list --id <id> --exact'.
#   5. Aggregates every failure and reports them together at the end.
#
# WHAT IT VERIFIES
#   - A real winget.exe exists (not the zero-byte AppExecutionAlias stub).
#   - The session is interactive, so a no-op install cannot be mistaken for a
#     successful one.
#   - Exit codes come from Start-Process -PassThru, NOT from $LASTEXITCODE,
#     which this binary does not set.
#   - An empty/null exit code is treated as a FAILURE, not as success. That is
#     precisely the signature of the non-interactive no-op.
#   - Per package: an acceptable install exit code AND 'winget list --id <id>
#     --exact' exiting 0, which is what catches an install that claimed success
#     and landed nothing.
#
# FAILURE CONTRACT
#   FATAL     : winget.exe cannot be found; the session is not interactive; or
#               any package fails its install exit code or its 'winget list'
#               check. Accepted install exit codes are 0, 3010 (reboot
#               required), -1978335189 (0x8A15002B, no applicable update) and
#               -1978335135 (0x8A150061, already installed).
#   LOUD SKIP : none. There is no condition under which this script should do
#               nothing and report success.
#
# NOTES
#   - NOT WIRED IN: no build references this script, by design. It is kept as
#     maintained library code for interactive use and for future automation
#     that runs in a user session (a logon task, an Ansible play against a
#     running VM with become_method runas, etc).
#   - $PSNativeCommandUseErrorActionPreference is disabled so PowerShell 7.4+
#     does not turn a non-zero native exit into a terminating error.
###############################################################################

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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

# winget exit codes that are not failures:
#   0           success
#   3010        success, reboot required
#   -1978335189 0x8A15002B no applicable update
#   -1978335135 0x8A150061 package already installed
$AcceptableExitCodes = @(0, 3010, -1978335189, -1978335135)

function Get-WingetPath {
    # Same resolution rule as 53-install-winget.ps1: prefer the real payload
    # under WindowsApps, and reject a zero-byte AppExecutionAlias stub.
    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    $packageDirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory `
            -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending)

    foreach ($dir in $packageDirs) {
        $candidate = Join-Path $dir.FullName 'winget.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) {
        $length = (Get-Item -LiteralPath $command.Source -ErrorAction SilentlyContinue).Length
        if ($length -gt 0) { return $command.Source }
    }

    return $null
}

function Test-InteractiveSession {
    # winget's install path needs a real user session. Session 0 is the
    # non-interactive services session that WinRM and scheduled tasks land in,
    # and that is exactly where the install silently does nothing.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $sessionId = (Get-Process -Id $PID).SessionId
    Write-Host "Running in session $sessionId as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    return ($sessionId -ne 0)
}

function Invoke-Winget {
    # Start-Process -PassThru because the bare call operator does NOT set
    # $LASTEXITCODE for this MSIX-packaged binary. Returns $null when no exit
    # code was produced at all, which the caller treats as a failure.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $stdout = Join-Path $env:TEMP "winget-out-$PID.txt"
    $stderr = Join-Path $env:TEMP "winget-err-$PID.txt"

    $process = Start-Process -FilePath $WingetPath -ArgumentList $Arguments `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    foreach ($file in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $file) {
            $text = (Get-Content -LiteralPath $file -Raw)
            if ($text -and $text.Trim()) { Write-Host $text.Trim() }
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }

    return $process.ExitCode
}

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/56-install-winget-packages.txt' -Append

try {
    $winget = Get-WingetPath
    if ($null -eq $winget) {
        throw "No runnable winget.exe found. Run 53-install-winget.ps1 first, and note that a staged package only becomes usable at the next logon."
    }
    Write-Host "Using winget at $winget"

    if (-not (Test-InteractiveSession)) {
        throw @'
Refusing to run: this is session 0, a non-interactive session.

winget's install path does nothing here. It returns no exit code, writes
nothing to stdout or stderr, raises no error, and installs no package - so
proceeding would report success for work that did not happen. This script
fails instead. Run it from a console or RDP logon.
'@
    }

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($packageId in $WingetPackages) {
        Write-Host ""
        Write-Host "Installing $packageId"

        $exitCode = Invoke-Winget -WingetPath $winget -Arguments @(
            'install', '--id', $packageId, '--exact', '--silent',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity'
        )

        if ($null -eq $exitCode) {
            $failures.Add("$packageId (no exit code returned - the hallmark of the non-interactive no-op)")
            continue
        }
        if ($AcceptableExitCodes -notcontains $exitCode) {
            $failures.Add("$packageId (winget exit code $exitCode)")
            continue
        }

        # Verify the effect: 'winget list' exits non-zero when nothing matches.
        $listCode = Invoke-Winget -WingetPath $winget -Arguments @(
            'list', '--id', $packageId, '--exact',
            '--disable-interactivity', '--accept-source-agreements'
        )
        if ($listCode -ne 0) {
            $failures.Add("$packageId (install exited $exitCode but 'winget list' cannot find it)")
            continue
        }

        Write-Host "Verified $packageId is installed"
    }

    if ($failures.Count -gt 0) {
        throw "$($failures.Count) of $($WingetPackages.Count) winget packages failed: $($failures -join '; ')"
    }

    Write-Host ""
    Write-Host "All $($WingetPackages.Count) winget packages installed and verified."
    exit 0
}
catch {
    Write-Host "Something went wrong: $($PSItem.Exception.Message)"

    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600 seconds before failing."
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
