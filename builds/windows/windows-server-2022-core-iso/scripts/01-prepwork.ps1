###############################################################################
# Name:             01-prepwork.ps1
# Description:      Prepare windows VM for packer provisioning
# Author:           Daniel Whicker
# Date:             2021-05-29
###############################################################################

$ErrorActionPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/01-prepwork.txt' -Append;

try {
    # Switch network connection to private mode
    # Required for WinRM firewall rules
    Write-Host "Switching network connection to private mode"
    $connectionProfile = Get-NetConnectionProfile
    While ($connectionProfile.Name -eq "Identifying...") {
        Start-Sleep -Seconds 10
        $connectionProfile = Get-NetConnectionProfile
    }
    Set-NetConnectionProfile -Name $connectionProfile.Name -NetworkCategory Private

    # Drop the firewall while building and re-enable as a standalone provisioner in the Packer file if needs be
    Write-Host "Disabling Windows firewall"
    netsh Advfirewall set allprofiles state off

    # Enable WinRM service
    Write-Host "Enabling WinRM service"
    winrm quickconfig -quiet
    # winrm set winrm/config/Listener?Address=*+Transport=HTTP '@{Port="22"}'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/service/auth '@{Basic="true"}'
    winrm set winrm/config/client/auth '@{Basic="true"}'
    winrm set winrm/config '@{MaxTimeoutms="7200000"}'
    winrm set winrm/config/winrs '@{IdleTimeout="7200000"}'
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'
    winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="12000"}'

    # Making double sure WinRM service is set to auto.
    Stop-Service WinRM
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service WinRM

    # Reset auto logon count
    # https://docs.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue
    Write-Host "Enabling initial auto login"
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0

    # Disable Network Discovery
    Write-Host "Disabling network discovery"
    reg ADD HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff /f
    netsh advfirewall firewall set rule group="Network Discovery" new enable=No
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

Start-Sleep -Seconds 10
