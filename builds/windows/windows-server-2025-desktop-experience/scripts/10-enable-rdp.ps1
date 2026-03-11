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
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 1 -ErrorAction SilentlyContinue

    Write-Host "Enable RDP Through Firewall"
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    Exit 1
}
