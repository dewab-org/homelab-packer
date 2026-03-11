###############################################################################
# Name:             03-install-virtio-guest-tools.ps1
# Description:      Install VirtIO guest tools (includes QEMU guest agent)
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:/Install/03-install-virtio-guest-tools.txt" -Append

function Get-GuestToolsInstaller {
    try {
        $cds = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue
        foreach ($cd in $cds) {
            $path = Join-Path $cd.Drive "virtio-win-guest-tools.exe"
            if (Test-Path $path) {
                return $path
            }
        }
    }
    catch {
        Write-Host "CD-ROM probe failed: $($_.Exception.Message)"
    }
    return $null
}

try {
    $installer = Get-GuestToolsInstaller
    if (-not $installer) {
        throw "virtio-win-guest-tools.exe not found on attached CD-ROMs"
    }

    Write-Host "Installing $installer"
    Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -NoNewWindow
}
finally {
    Stop-Transcript | Out-Null
}

