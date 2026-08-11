###############################################################################
# Name:             bootstrap.ps1
# Description:      Bootstraps WinRM during first logon (called by Autounattend)
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:\\Windows\\Temp\\packer-bootstrap.txt" -Append

function Get-CDRomDrives {
    try {
        return (Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | ForEach-Object { $_.Drive }) | Where-Object { $_ }
    }
    catch {
        return @()
    }
}

function Find-VirtioToolsPath {
    foreach ($d in (Get-CDRomDrives)) {
        $p = Join-Path $d "virtio-win-guest-tools.exe"
        if (Test-Path $p) {
            return $p
        }
    }
    return $null
}

try {
    # This script runs from the PACKER ISO root; use that location directly.
    $mediaRoot = $PSScriptRoot
    if (-not $mediaRoot -or -not (Test-Path $mediaRoot)) {
        throw "Unable to determine PACKER media root"
    }

    New-Item -Path "C:\\Install" -ItemType Directory -Force | Out-Null
    New-Item -Path "C:\\Install\\scripts" -ItemType Directory -Force | Out-Null

    Copy-Item -Path (Join-Path $mediaRoot "scripts\\*.ps1") -Destination "C:\\Install\\scripts" -Force

    # Keep bootstrap minimal and resilient: get WinRM HTTP up for initial Packer
    # connectivity. More advanced remoting config runs later via provisioners.
    & "C:\\Install\\scripts\\02-enable-winrm.ps1"

    $virtioTools = Find-VirtioToolsPath
    if ($virtioTools) {
        Write-Host "Installing VirtIO guest tools from $virtioTools"
        Start-Process -FilePath $virtioTools -ArgumentList "/install", "/quiet", "/norestart" -Wait
    }
    else {
        Write-Host "VirtIO guest tools not found on any CD-ROM drive; skipping install"
    }
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
