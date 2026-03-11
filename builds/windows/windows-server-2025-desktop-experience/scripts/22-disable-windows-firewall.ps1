###############################################################################
# Name:             22-disable-windows-firewall.ps1
# Description:      Disable Windows Firewall for all profiles (Domain, Private, Public)
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################

# Start transcript to log actions
$logPath = 'C:/Install/22-disable-windows-firewall.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

Write-Host "Disabling Windows Firewall"

# Function to disable Windows Firewall for all profiles
function Disable-WindowsFirewall {
    try {
        # Disable the firewall for Domain, Private, and Public profiles
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False

        Write-Output "Windows Firewall has been disabled for all profiles (Domain, Private, Public)."
    }
    catch {
        Write-Error "Failed to disable Windows Firewall: $_"
    }
}

# Function to confirm the firewall status
function Confirm-FirewallStatus {
    try {
        $profiles = Get-NetFirewallProfile -Profile Domain, Private, Public | Select-Object Name, Enabled
        Write-Output "Firewall status:"
        $profiles | ForEach-Object {
            Write-Output "$($_.Name) profile is $([bool]$_.Enabled)"
        }
    }
    catch {
        Write-Error "Failed to retrieve firewall status: $_"
    }
}

# Execute the functions
Disable-WindowsFirewall
Confirm-FirewallStatus

# Stop transcript
Stop-Transcript
