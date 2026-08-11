###############################################################################
# Name:             10-enable-rdp.ps1
# Description:      Enable RDP
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/10-enable-rdp.txt' -Append;

try {
    Write-Host "Enabling RDP"
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0

    Write-Host "Enable RDP Through Firewall"
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
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
