###############################################################################
# Name:             57-windows-subsys-linux-part1.ps1
# Description:      Install Windows Subsystem for Linux
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/57-windows-subsys-linux.txt' -Append;

Write-Host "Configuring WSL"

try {
    Write-Host "Enabling Virtual Machine Platform"
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

    Write-Host "Enabling WSL"
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
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
