###############################################################################
# Name:             12-enable-openssh.ps1
# Description:      Install and enable the built-in OpenSSH server
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/12-enable-openssh.txt' -Append

try {
    $capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capabilityName

    if ($capability.State -ne 'Installed') {
        Write-Host "Installing OpenSSH Server capability"
        Add-WindowsCapability -Online -Name $capabilityName
    }

    Write-Host "Configuring sshd service"
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
    }
    else {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (TCP-In)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host
    Exit 1
}
finally {
    Stop-Transcript
}
