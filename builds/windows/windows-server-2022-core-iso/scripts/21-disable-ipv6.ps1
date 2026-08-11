###############################################################################
# Name:             21-disable-ipv6.ps1
# Description:      Disable IPv6 in the registry and on network adapters
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################

# Start transcript to log actions
$logPath = 'C:/Install/21-disable-ipv6.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

Write-Host "Disabling IPv6"

# Function to disable IPv6 by modifying the registry
function Disable-IPv6 {
    try {
        $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
        $name = "DisabledComponents"
        $value = 0xFF

        # Create the key if it doesn't exist
        if (-not (Test-Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        # Set the registry value
        Set-ItemProperty -Path $registryPath -Name $name -Value $value -Type DWord
        Write-Output "IPv6 has been disabled in the registry."
    }
    catch {
        Write-Error "Failed to disable IPv6 in the registry: $_"
    }
}

# Function to disable IPv6 on network adapters
function Disable-IPv6OnAdapters {
    try {
        # Get all network adapters
        $adapters = Get-NetAdapter

        foreach ($adapter in $adapters) {
            try {
                # Disable IPv6
                Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6
                Write-Output "IPv6 has been disabled on adapter: $($adapter.Name)"
            }
            catch {
                Write-Error "Failed to disable IPv6 on adapter $($adapter.Name): $_"
            }
        }
    }
    catch {
        Write-Error "Failed to retrieve network adapters: $_"
    }
}

# Execute the functions
Disable-IPv6
Disable-IPv6OnAdapters

Write-Output "IPv6 disable script execution completed."

# Note: Restart is required, but will be handled by Packer script

# Stop transcript
Stop-Transcript
