###############################################################################
# Name:             21-enable-openssh.ps1
# Description:      Installs the built-in OpenSSH Server Windows capability,
#                   sets sshd to start automatically and starts it, and opens
#                   inbound TCP/22 in the Windows Firewall. Every one of those
#                   effects is read back off the live system before success.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install (Start-Transcript throws without it) and opens a
#      transcript at C:\Install\21-enable-openssh.txt.
#   2. Resolves the capability by wildcard 'OpenSSH.Server*' rather than a
#      literal name - the version suffix (~~~~0.0.1.0) is not stable across
#      Windows releases.
#   3. Runs Add-WindowsCapability when the capability is not already
#      Installed, printing a loud banner if the add reports RestartNeeded.
#   4. Sets the sshd service to StartupType Automatic and starts it.
#   5. Creates the inbound firewall rule 'OpenSSH-Server-In-TCP', or updates
#      it in place if a rule with that -Name already exists (TCP/22, Allow,
#      Profile Any, Enabled).
#
# WHAT IT VERIFIES
#   - An 'OpenSSH.Server*' capability is offered by the image at all. Its
#     absence means this Windows edition cannot provide OpenSSH, and the
#     build must not continue as though SSH will be there.
#   - The capability re-reads as State=Installed after the add. Anything
#     else is a silently incomplete install.
#   - sshd reports Status=Running AND StartType=Automatic. A Manual or
#     Disabled start type would leave every clone of this template without
#     SSH after its first boot, which is invisible until someone tries it.
#   - Something is genuinely listening on TCP/22, polled up to 15 times at
#     2s intervals. A "Running" service that never binds the port is the
#     precise failure this catches.
#   - The firewall rule exists, is Enabled=True, has Action=Allow, and its
#     port filter really covers local port 22 - not merely that a rule with
#     that name came back.
#
# FAILURE CONTRACT
#   FATAL     : no OpenSSH.Server capability in the image; capability not
#               Installed after Add-WindowsCapability; sshd not Running or
#               not Automatic; nothing listening on TCP/22 after ~30s of
#               polling; firewall rule missing, disabled, not Allow, or
#               bound to a port other than 22. All of these exit 1 and fail
#               the provisioner.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
# NOTES
#   - RestartNeeded is surfaced as a banner instead of being discarded:
#     there is NO windows-restart provisioner anywhere in this repo, so if
#     it ever reports true the caller MUST add one after this script. The
#     capability-state assertion below the banner still runs, so a genuinely
#     incomplete install fails the build rather than sliding through.
#   - The explicit 'exit 0' is load-bearing. Packer's default powershell
#     execute_command ends with 'exit $LastExitCode', so falling off the end
#     would hand the build's verdict to whatever stale exit code the last
#     native command left behind.
#   - Wired into every Windows build: the 2022 and 2025 Core and Desktop
#     Experience ISO builds, and common/cloud-clone-build.pkr.hcl.
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

# Start-Transcript throws if the directory is missing. Do not rely on an
# earlier provisioner having created C:\Install.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null

Start-Transcript -Path 'C:/Install/21-enable-openssh.txt' -Append

try {
    # Resolve the capability dynamically - the version suffix in
    # OpenSSH.Server~~~~0.0.1.0 is not stable across Windows releases.
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if (-not $capability) {
        throw "This Windows image does not offer an 'OpenSSH.Server*' capability."
    }
    $capabilityName = $capability.Name
    Write-Host "Found OpenSSH capability '$capabilityName' (State=$($capability.State))"

    if ($capability.State -ne 'Installed') {
        Write-Host "Installing OpenSSH Server capability"
        $addResult = Add-WindowsCapability -Online -Name $capabilityName
        if ($addResult -and $addResult.RestartNeeded) {
            # Surfaced rather than discarded: there is no windows-restart
            # provisioner in this repo, so the caller must add one if this
            # ever reports true. The capability state assertion below still
            # runs, so a genuinely incomplete install fails the build.
            Write-Host "***************************************************************"
            Write-Host "*** WARNING: RESTART NEEDED                                 ***"
            Write-Host "*** Add-WindowsCapability reports RestartNeeded=True for    ***"
            Write-Host "*** '$capabilityName'."
            Write-Host "*** There is no windows-restart provisioner in this repo -  ***"
            Write-Host "*** the caller MUST add one after this script.              ***"
            Write-Host "***************************************************************"
        }
    }

    # Verify the effect: re-query the capability from the live image.
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne 'Installed') {
        throw "OpenSSH capability '$capabilityName' is in state '$($capability.State)' after install, expected 'Installed'."
    }
    Write-Host "Verified OpenSSH capability '$capabilityName' is Installed"

    Write-Host "Configuring sshd service"
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    # Verify the effect: service must be running and set to start at boot.
    $sshd = Get-Service -Name sshd
    if ($sshd.Status -ne 'Running') {
        throw "sshd service status is '$($sshd.Status)' after Start-Service, expected 'Running'."
    }
    if ($sshd.StartType -ne 'Automatic') {
        throw "sshd service start type is '$($sshd.StartType)', expected 'Automatic'."
    }
    Write-Host "Verified sshd: Status=$($sshd.Status) StartType=$($sshd.StartType)"

    # Verify the effect: something must actually be listening on TCP/22.
    $listener = $null
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $listener) {
        throw "Nothing is listening on TCP/22 after starting sshd."
    }
    Write-Host "Verified TCP/22 listener on $($listener.LocalAddress) (pid $($listener.OwningProcess))"

    $sshRuleName = 'OpenSSH-Server-In-TCP'
    if (Get-NetFirewallRule -Name $sshRuleName -ErrorAction SilentlyContinue) {
        Write-Host "Updating existing firewall rule '$sshRuleName'"
        Set-NetFirewallRule -Name $sshRuleName -Direction Inbound -Protocol TCP -LocalPort 22 `
            -Action Allow -Profile Any -Enabled True
    }
    else {
        Write-Host "Creating firewall rule '$sshRuleName'"
        New-NetFirewallRule -Name $sshRuleName -DisplayName 'OpenSSH Server (TCP-In)' -Direction Inbound `
            -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -Enabled True | Out-Null
    }

    # Verify the effect: read the firewall rule back.
    $liveRule = Get-NetFirewallRule -Name $sshRuleName -ErrorAction SilentlyContinue
    if (-not $liveRule) {
        throw "Firewall rule '$sshRuleName' does not exist after configuration."
    }
    if ([string]$liveRule.Enabled -ne 'True') {
        throw "Firewall rule '$sshRuleName' is not enabled (Enabled=$([string]$liveRule.Enabled))."
    }
    if ([string]$liveRule.Action -ne 'Allow') {
        throw "Firewall rule '$sshRuleName' has action $([string]$liveRule.Action), expected Allow."
    }
    $sshFilter = $liveRule | Get-NetFirewallPortFilter
    if ([string]$sshFilter.LocalPort -ne '22') {
        throw "Firewall rule '$sshRuleName' covers local port $([string]$sshFilter.LocalPort), expected 22."
    }
    Write-Host "Verified firewall rule '$sshRuleName': Enabled=$([string]$liveRule.Enabled) LocalPort=$([string]$sshFilter.LocalPort)"

    Write-Host "OpenSSH server installed, running and reachable on TCP/22"

    # Explicit success code. Packer's default powershell execute_command ends
    # with 'exit $LastExitCode', which would otherwise propagate whatever a
    # stale native command left behind.
    exit 0
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Optional debug hold so the error is readable before Packer destroys the VM.
    if ($env:PACKER_DEBUG_HOLD) {
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
