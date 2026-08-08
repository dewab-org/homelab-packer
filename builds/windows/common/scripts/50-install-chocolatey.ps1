###############################################################################
# Name:             50-install-chocolatey.ps1
# Description:      Install chocolatey (requires Internet access)
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################

Start-Transcript -Path 'C:/Install/50-install-chocolatey.txt' -Append;

Write-Host "Installing Chocolatey"

$installScript = 'C:\Windows\Temp\install.ps1'

# Chocolatey requires modern TLS; older defaults can fail during bootstrap.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -OutFile $installScript -UseBasicParsing

$env:chocolateyUseWindowsCompression = 'false'
for ($try = 0; $try -lt 5; $try++) {
    if (-not (Test-Path $installScript)) {
        Write-Host "Chocolatey install script missing (Try #${try})"
        Start-Sleep 2
        continue
    }

    & $installScript
    if ($?) { exit 0 }
    if (Test-Path C:\ProgramData\chocolatey) { exit 0 }
    Write-Host "Failed to install chocolatey (Try #${try})"
    Start-Sleep 2
}
Write-Warning "Chocolatey failed to install; continuing without Chocolatey-managed packages"
exit 0
