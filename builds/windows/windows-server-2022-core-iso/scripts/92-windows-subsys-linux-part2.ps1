###############################################################################
# Name:             92-windows-subsys-linux-part2.ps1
# Description:      Set WSL default to v2 after reboot
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################

###############################################################################
# Variables
###############################################################################

$distribution_url = "https://aka.ms/wslubuntu2204" # Ubuntu-20.04 LTS
$kernel_url = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"

###############################################################################
# Script
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/92-windows-subsys-linux-part2.txt' -Append;

try {
    Write-Host "Download Kernel Update for WSL2"
    Invoke-WebRequest -Uri $kernel_url -OutFile c:\Install\wsl_update_x64.msi

    Write-Host "Installing Kernel Update for WSL2"
    Start-Process c:\Install\wsl_update_x64.msi -ArgumentList "/quiet /norestart"

    Write-Host "Enabling WSL Version 2 by Default"
    wsl --set-default-version 2

    Write-Host "Downloading Linux Distribution ($distribution_url)"
    Invoke-WebRequest -Uri $distribution_url -OutFile c:\Install\Linux.appx -UseBasicParsing

    Write-Host "Installing Distribution"
    Add-AppxPackage c:\Install\Linux.appx
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Sleep for 60 minutes so you can see the errors before the VM is destroyed by Packer.
    Start-Sleep -Seconds 3600

    Exit 1
}
