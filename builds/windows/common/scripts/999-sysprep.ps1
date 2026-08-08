###############################################################################
# Name:             999-sysprep.ps1
# Description:      Rename default users and perform Sysprep if not running on VMware
# Author:           Daniel Whicker
# Date:             2024-05-02
###############################################################################

# Set preferences to control script behavior
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

function Get-VMware {
    try {
        $biosManufacturer = (Get-CimInstance -ClassName Win32_BIOS).Manufacturer
        $vmwareKeywords = @("VMware", "VMW")

        foreach ($keyword in $vmwareKeywords) {
            if ($biosManufacturer -like "*$keyword*") {
                return $true
            }
        }

        # Check for VMware specific registry keys
        $vmwareRegKey = "HKLM:\SYSTEM\CurrentControlSet\Services\vmhgfs"
        if (Test-Path $vmwareRegKey) {
            return $true
        }

        return $false
    }
    catch {
        Write-Host "Error determining VMware status:"
        Write-Host $_.Exception.Message
        return $false
    }
}

try {
    if (Get-VMware) {
        Write-Host "Running on a VMware VM. Exiting script successfully."
        Exit 0
    }
    else {
        Write-Host "Not running on a VMware VM. Proceeding with Sysprep."

        # Run Sysprep with specified parameters
        & "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit
        Write-Host "Sysprep completed successfully."
    }
}
catch {
    Write-Host "Something went wrong:"
    Write-Host $_.Exception.Message

    # Sleep for 60 minutes to allow error inspection before VM destruction
    Start-Sleep -Seconds 3600
    Exit 1
}
