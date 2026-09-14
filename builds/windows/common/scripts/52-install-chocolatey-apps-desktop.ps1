###############################################################################
# Name:             52-install-chocolatey-apps-desktop.ps1
# Description:      Installs a fixed list of seventeen Desktop-Experience-only
#                   Chocolatey packages (editors, terminals, remote-access
#                   clients) and proves each one landed by checking that
#                   Chocolatey registered it under <chocoRoot>\lib\<package>.
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\52-install-chocolatey-apps-desktop.txt.
#   2. Resolves choco.exe in \bin under $env:ChocolateyInstall (else
#      %ProgramData%\chocolatey), falling back to PATH. When it falls back it
#      re-derives the Chocolatey root from the exe it actually resolved.
#   3. Runs `choco --version` to prove Chocolatey works at all.
#   4. Installs each package with `choco install <id> --no-progress -y`:
#      baretail, git.install, microsoft-windows-terminal, procexp, rdcman,
#      rufus.install, rvtools, vmrc, vmware-horizon-client, vscode.install,
#      vscode-ansible, vscode-docker, vscode-markdownlint, vscode-powershell,
#      vscode-python, vscode-yaml, Xming.
#   5. Collects every failure and reports them together at the end.
#
# WHAT IT VERIFIES
#   - Chocolatey is present AND runnable before anything is installed.
#   - Two independent gates per package: the choco exit code is 0 or 3010
#     (3010 = installed but wants a reboot), AND the package directory
#     <chocoRoot>\lib\<package> exists afterwards. The second gate is what
#     catches a choco run that exits 0 while registering nothing.
#
# FAILURE CONTRACT
#   FATAL     : no choco.exe found at the expected path or on PATH
#               (50-install-chocolatey.ps1 must have run and succeeded
#               first); choco.exe exists but `--version` exits non-zero; one
#               or more packages fail either gate - the count and the reason
#               for each are aggregated into a single error.
#   LOUD SKIP : the package list is empty - logs "SKIPPED: no Chocolatey apps
#               configured" and exits 0. It is not currently empty.
#
# INPUTS (environment)
#   ChocolateyInstall   Chocolatey root override; falls back to
#                       %ProgramData%\chocolatey when unset.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. Chocolatey is deliberately not installed on
#     these templates; no *.pkr.hcl references this script (or 50/51). It is
#     kept as a library script.
#   - Desktop Experience only. Do not run this on Server Core.
#   - A missing Chocolatey is a hard failure here, never a reason to skip.
#   - choco is a native command and does not throw, so a try/catch around it
#     would be dead code; $LASTEXITCODE has to be read explicitly.
#   - Re-deriving $chocoRoot from the resolved exe matters: keeping the
#     guessed root would point every lib\<pkg> assertion at the wrong
#     directory and report bogus failures for packages that did install.
###############################################################################

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# PowerShell 7.4+ turns a non-zero NATIVE exit code into a terminating error
# while $ErrorActionPreference is 'Stop', which would bypass the explicit
# $LASTEXITCODE checks below. Harmless no-op on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

###############################################################################
# Apps to Install
###############################################################################

$ChocolateyAppsToInstall = @('baretail', 'git.install', 'microsoft-windows-terminal', 'procexp', 'rdcman', 'rufus.install', 'rvtools', 'vmrc', 'vmware-horizon-client', 'vscode.install', 'vscode-ansible', 'vscode-docker', 'vscode-markdownlint', 'vscode-powershell', 'vscode-python', 'vscode-yaml', 'Xming')

# choco returns 3010 when a package installed fine but wants a reboot.
$AcceptableExitCodes = @(0, 3010)

###############################################################################
# Main
###############################################################################

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/52-install-chocolatey-apps-desktop.txt' -Append

try {
    ###########################################################################
    # Chocolatey is a hard requirement
    ###########################################################################
    $chocoRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { Join-Path $env:ProgramData 'chocolatey' }
    $chocoExe = Join-Path $chocoRoot 'bin\choco.exe'

    if (-not (Test-Path -LiteralPath $chocoExe)) {
        $command = Get-Command choco.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw "Chocolatey is not installed (no choco.exe at $chocoExe and none on PATH). 50-install-chocolatey.ps1 must run and succeed before this script."
        }
        $chocoExe = $command.Source
        # Derive the root from the exe we actually resolved. Keeping the guessed
        # $chocoRoot here would make every lib\<pkg> assertion below look at the
        # wrong directory and report bogus failures for packages that installed.
        $chocoRoot = Split-Path -Path (Split-Path -Path $chocoExe -Parent) -Parent
    }

    & $chocoExe --version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$chocoExe exists but 'choco --version' exited $LASTEXITCODE; Chocolatey is broken."
    }

    if ($ChocolateyAppsToInstall.Count -eq 0) {
        Write-Host "SKIPPED: no Chocolatey apps configured, so nothing was installed."
        exit 0
    }

    ###########################################################################
    # Install and verify each package
    ###########################################################################
    # choco is a native command: it does NOT throw, so try/catch around it is
    # dead code. $LASTEXITCODE has to be read explicitly, and the package has
    # to be proven present afterwards.
    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($app in $ChocolateyAppsToInstall) {
        Write-Host "Installing $app"
        & $chocoExe install $app --no-progress -y

        if ($AcceptableExitCodes -notcontains $LASTEXITCODE) {
            $failures.Add("$app (choco exit code $LASTEXITCODE)")
            continue
        }

        $packageDir = Join-Path $chocoRoot "lib\$app"
        if (-not (Test-Path -LiteralPath $packageDir)) {
            $failures.Add("$app (choco exited 0 but the package is not registered at $packageDir)")
            continue
        }

        Write-Host "Verified $app is registered at $packageDir"
    }

    if ($failures.Count -gt 0) {
        throw "$($failures.Count) of $($ChocolateyAppsToInstall.Count) Chocolatey packages failed: $($failures -join '; ')"
    }

    Write-Host "All $($ChocolateyAppsToInstall.Count) Chocolatey packages installed and verified."
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
