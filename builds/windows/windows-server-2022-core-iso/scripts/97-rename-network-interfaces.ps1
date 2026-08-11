###############################################################################
# Name:             97-rename-network-interfaces.ps1
# Description:      Rename default users
# Author:           Daniel Whicker
# Date:             2024-05-02
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$AdapterMapping = @{
    # Old adapter name = New adapter name
    "Ethernet0" = "Grey_VLAN"
    "Ethernet1" = "Green_VLAN"
}

Start-Transcript -Path 'C:/Install/97-rename-network-interfaces.txt' -Append

try {
    $adapters = Get-NetAdapter | Where-Object { $_.Name -ne "Loopback" }
    $adapterCount = $adapters.Count

    if ($adapterCount -ne 2) {
        Write-Host "Only rename network interfaces if there are exactly two network interfaces. Found: $adapterCount"
        Exit 0
    }

    foreach ($OldAdapterName in $AdapterMapping.Keys) {
        $NewAdapterName = $AdapterMapping[$OldAdapterName]
        Write-Host "Renaming $OldAdapterName to $NewAdapterName"
        Get-NetAdapter -Name $OldAdapterName | Rename-NetAdapter -NewName $NewAdapterName
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($_.Exception.Message)
    Write-Host

    Exit 1
}
finally {
    Stop-Transcript
}
