###############################################################################
# Name:             55-install-chocolatey-apps.ps1
# Description:      Installs third-party apps using chocolatey
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################

Start-Transcript -Path 'C:/Install/55-install-chocolatey-apps.txt' -Append;

###############################################################################
# Apps to Install
###############################################################################

$ChocolateyAppsToInstall = @('7zip.install', 'bginfo', 'chocolateygui', 'firefox', 'googlechrome', 'notepadplusplus.install', 'pinginfoview', 'treesizefree')

###############################################################################
# Check For Chocolatey
###############################################################################

try {
    & choco -v > $null
}
catch {
    Write-Output "Chocolatey not detected, skipping package install"
    exit 0
}

###############################################################################
# Install Applications
###############################################################################

if ($ChocolateyAppsToInstall.Count -gt 0) {
    Write-Host "Chocolatey Apps Specified"
    foreach ($ApplicationToInstall in $ChocolateyAppsToInstall) {
        Write-Host "Installing $ApplicationToInstall"
        try {
            & choco install --no-progress -y $ApplicationToInstall | Write-Output
        }
        catch {
            Write-Output "Failed to install $ApplicationToInstall"
        }
    }
}

Stop-Transcript
