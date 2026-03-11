###############################################################################
# Name:             bootstrap.ps1
# Description:      Bootstraps WinRM during first logon (called by Autounattend)
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:\\Windows\\Temp\\packer-bootstrap.txt" -Append

try {
    # This script runs from the PACKER ISO root; use that location directly.
    $mediaRoot = $PSScriptRoot
    if (-not $mediaRoot -or -not (Test-Path $mediaRoot)) {
        throw "Unable to determine PACKER media root"
    }

    New-Item -Path "C:\\Install" -ItemType Directory -Force | Out-Null
    New-Item -Path "C:\\Install\\scripts" -ItemType Directory -Force | Out-Null

    Copy-Item -Path (Join-Path $mediaRoot "scripts\\*.ps1") -Destination "C:\\Install\\scripts" -Force

    # Enable the core management paths during unattended setup so the template
    # is reachable even before later provisioners run.
    & "C:\\Install\\scripts\\02-enable-winrm.ps1"
    & "C:\\Install\\scripts\\10-enable-rdp.ps1"
    & "C:\\Install\\scripts\\12-enable-openssh.ps1"
}
catch {
    Write-Host "bootstrap failed: $($_.Exception.Message)"
    "bootstrap failed: $($_.Exception.Message)" | Out-File -FilePath "C:\\Windows\\Temp\\packer-bootstrap.failed" -Encoding ascii -Force
    # Never fail Windows setup because of bootstrap; Packer can still connect
    # once manual/secondary remediation is applied.
    exit 0
}
finally {
    Stop-Transcript | Out-Null
}
