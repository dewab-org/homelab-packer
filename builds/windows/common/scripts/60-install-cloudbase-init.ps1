###############################################################################
# Name:             60-install-cloudbase-init.ps1
# Description:      Optionally install Cloudbase-Init for Proxmox cloud-init
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/60-install-cloudbase-init.txt' -Append

try {
    $installerUrl = $env:CLOUDBASE_INIT_URL
    $checksum = $env:CLOUDBASE_INIT_CHECKSUM

    if ([string]::IsNullOrWhiteSpace($installerUrl)) {
        Write-Host "Cloudbase-Init URL not set. Skipping Cloudbase-Init installation."
        exit 0
    }

    $installerPath = 'C:\Install\cloudbase-init.msi'
    Write-Host "Downloading Cloudbase-Init from $installerUrl"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($checksum) -and $checksum -ne 'none') {
        $parts = $checksum.Split(':', 2)
        if ($parts.Count -eq 2) {
            $algo = $parts[0].ToUpper()
            $expected = $parts[1].ToLower()
            $actual = (Get-FileHash -Path $installerPath -Algorithm $algo).Hash.ToLower()
            if ($actual -ne $expected) {
                throw "Cloudbase-Init checksum mismatch"
            }
        }
    }

    Write-Host "Installing Cloudbase-Init"
    Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $installerPath, '/qn', '/norestart') -Wait
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host
    Exit 1
}
finally {
    Stop-Transcript
}
