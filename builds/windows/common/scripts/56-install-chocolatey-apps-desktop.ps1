###############################################################################
# Name:             56-install-chocolatey-apps-desktop.ps1
# Description:      Installs third-party apps using chocolatey
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################

Start-Transcript -Path 'C:/Install/56-install-chocolatey-apps-desktop.txt' -Append;

###############################################################################
# Apps to Install
###############################################################################

$ChocolateyAppsToInstall = @('baretail', 'git.install', 'microsoft-windows-terminal', 'procexp', 'rdcman', 'rufus.install', 'rvtools', 'vmrc', 'vmware-horizon-client', 'vscode.install', 'vscode-ansible', 'vscode-docker', 'vscode-markdownlint', 'vscode-powershell', 'vscode-python', 'vscode-yaml', 'Xming')

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
