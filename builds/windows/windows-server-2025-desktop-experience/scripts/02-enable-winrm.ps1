###############################################################################
# Name:             02-enable-winrm.ps1
# Description:      Minimal WinRM enablement for Packer provisioning
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:/Windows/Temp/02-enable-winrm.txt" -Append

try {
    Write-Host "Enabling WinRM service"
    winrm quickconfig -quiet

    # Homelab build: keep it simple; ConfigureRemotingForAnsible will set up HTTPS.
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/service/auth '@{Basic="true"}'
    winrm set winrm/config/client/auth '@{Basic="true"}'
    winrm set winrm/config '@{MaxTimeoutms="7200000"}'
    winrm set winrm/config/winrs '@{IdleTimeout="7200000"}'

    Stop-Service WinRM -ErrorAction SilentlyContinue
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service WinRM

    Write-Host "Allowing WinRM through firewall (5985/5986)"
    netsh advfirewall firewall add rule name="Allow WinRM HTTP" dir=in action=allow protocol=TCP localport=5985 profile=any | Out-Null
    netsh advfirewall firewall add rule name="Allow WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986 profile=any | Out-Null
}
catch {
    Write-Host "Failed enabling WinRM: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}

