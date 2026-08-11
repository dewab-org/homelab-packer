###############################################################################
# Name:             90-customization.ps1
# Description:      Post-install Windows Customizations
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/90-customization.txt' -Append

function Remove-RegistryPathIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -Path $Path) {
        Remove-Item -Path $Path -Force
    }
    else {
        Write-Host "Skipping missing path: $Path"
    }
}

try {
    # Remove Documents from This PC
    Write-Host "Remove Documents Folder"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A8CDFF1C-4878-43be-B5FD-F8091C1C60D0}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{d3162b92-9365-467a-956b-92703aca08af}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A8CDFF1C-4878-43be-B5FD-F8091C1C60D0}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{d3162b92-9365-467a-956b-92703aca08af}"

    # Remove Music from This PC
    Write-Host "Remove Music Folder"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{1CF1260C-4DD0-4ebb-811F-33C572699FDE}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{1CF1260C-4DD0-4ebb-811F-33C572699FDE}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}"

    # Remove Pictures from This PC
    Write-Host "Remove Pictures Folder"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3ADD1653-EB32-4cb0-BBD7-DFA0ABB5ACCA}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{24ad3ad4-a569-4530-98e1-ab02f9417aa8}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{3ADD1653-EB32-4cb0-BBD7-DFA0ABB5ACCA}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{24ad3ad4-a569-4530-98e1-ab02f9417aa8}"

    # Remove Videos from This PC
    Write-Host "Remove Videos Folder"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A0953C92-50DC-43bf-BE83-3742FED03C9C}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{A0953C92-50DC-43bf-BE83-3742FED03C9C}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}"

    # Remove 3D Objects from This PC
    Write-Host "Remove 3D Objects Folder"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"
    Remove-RegistryPathIfExists -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"

    # Disable Ease of Access keyboard shortcuts
    Write-Host "Disable Ease of Access keyboard shortcuts"
    if ($(Get-WindowsEdition -Online).Edition -notmatch "cor") {
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "506"
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Value "122"
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Value "58"
    }

    # Setting view options
    Write-Host "Set Sensible Explorer View Defaults"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideDrivesWithNoMedia" -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Value 0

    # Setting default explorer view to This PC
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1

    Write-Host "Set Sensible Taskbar Defaults"
    # Show all icons in the taskbar notification area
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" -Name "EnableAutoTray" -Value 0

    # Small taskbar & combine when full
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\" -Name "TaskbarSmallIcons" -Value 1
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\" -Name "TaskbarGlomLevel" -Value 1

    # Set power plan to High Performance.
    Write-Host "Setting power plan to high performance..."
    $p = Get-CimInstance -Namespace "root\cimv2\power" -ClassName "win32_PowerPlan" -Filter "ElementName = 'High Performance'"
    powercfg /setactive ([string]$p.InstanceID).Replace("Microsoft:PowerPlan\{", "").Replace("}", "")

    # Disable hibernation
    Write-Host "Disable hibernation"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\" -Name "HiberFileSizePercent" -Value 0
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\" -Name "HibernateEnabled" -Value 0

    # Disable server manager from starting on login
    Write-Host "Disable server manager from starting on login"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1

    # Disable sleep
    Write-Host "Disable sleep"
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0

    # Disable password expiration for Administrator
    # Write-Host "Disable Administrator password expiration"
    # Set-LocalUser -Name "Administrator" -PasswordNeverExpires $true
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
