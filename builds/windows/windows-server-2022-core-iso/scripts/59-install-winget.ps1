###############################################################################
# Name:             InstallApplications.ps1
# Description:      Installs a list of applications using Winget
# Author:           Daniel Whicker
# Date:             2021-10-28
###############################################################################

###############################################################################
# Applications to Install
###############################################################################

$WinGetApplicationsToInstall = @(
    'Google.Chrome',
    'Notepad++.Notepad++',
    'Mozilla.Firefox',
    '7zip.7zip',
    'JAMSoftware.TreeSize.Free',
    'git.git'
)

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

# Start transcript to log the installation process
Start-Transcript -Path 'C:/Install/InstallLog.txt' -Append

try {
    # Check if Winget is installed
    $hasPackageManager = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue

    if (!$hasPackageManager) {
        Write-Host "Winget is not installed. Installing Winget..."

        # Install VCLibs if not already installed
        Add-AppxPackage -Path 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'

        # Get the latest release of Winget
        $releases_url = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $releases = Invoke-RestMethod -Uri $releases_url
        $latestRelease = $releases.assets | Where-Object { $_.browser_download_url.EndsWith('msixbundle') } | Select-Object -First 1

        Write-Host "Installing Winget from $($latestRelease.browser_download_url)"
        Add-AppxPackage -Path $latestRelease.browser_download_url
    }
    else {
        Write-Host "Winget is already installed."
    }

    # Install each application from the list
    foreach ($ApplicationToInstall in $WinGetApplicationsToInstall) {
        Write-Host "Installing $ApplicationToInstall..."
        winget install --id $ApplicationToInstall --silent --accept-package-agreements --accept-source-agreements

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to install $ApplicationToInstall"
        }
        else {
            Write-Host "$ApplicationToInstall installed successfully"
        }
    }

    Write-Host "All applications have been installed."
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($_.Exception.Message)
    Write-Host

    # Sleep for 60 minutes to allow for error checking before the VM is destroyed by Packer.
    Start-Sleep -Seconds 3600

    Exit 1
}
finally {
    # Stop transcript
    Stop-Transcript
}

# Reset error preference
$ErrorActionPreference = "Continue"
