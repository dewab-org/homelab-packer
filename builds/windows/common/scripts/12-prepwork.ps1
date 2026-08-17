###############################################################################
# Name:             12-prepwork.ps1
# Description:      Prepare a Windows VM for Packer provisioning: network
#                   profiles -> Private, Windows firewall OFF, WinRM
#                   configured and proven answering, auto-logon count reset.
# Author:           Daniel Whicker
# Date:             2021-05-29
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\12-prepwork.txt (append).
#   2. Waits up to 5 minutes for the network connection profile(s) to stop
#      reporting "Identifying...".
#   3. Sets every non-DomainAuthenticated connection profile to Private, then
#      re-reads them.
#   4. Turns the Windows firewall OFF for all profiles via netsh (see the
#      WARNING in NOTES - nothing here turns it back on).
#   5. Runs `winrm quickconfig -quiet` and applies seven settings with
#      `winrm set`: service AllowUnencrypted=true, service auth Basic=true,
#      client auth Basic=true, MaxTimeoutms=7200000, winrs IdleTimeout=
#      7200000, winrs MaxMemoryPerShellMB=2048 and service
#      MaxConcurrentOperationsPerUser=12000.
#   6. Stops WinRM, sets it to Automatic, starts it, then asserts the end
#      state and reads all seven values back off the live WSMan config.
#   7. Sets HKLM Winlogon AutoLogonCount to 0 and reads it back.
#   8. Creates the NewNetworkWindowOff key to suppress network discovery, then
#      attempts to disable the "Network Discovery" firewall rule group.
#
# WHAT IT VERIFIES
#   - Profiles leave "Identifying..." within 5 minutes. A NIC that never does
#     must fail the build loudly rather than hang the provisioner forever.
#   - No connection profile is left as anything but Private or
#     DomainAuthenticated. Failure means WinRM firewall rules would not apply.
#   - netsh's exit code, and then that no firewall profile is still Enabled -
#     netsh returning 0 is not proof the state changed.
#   - The exit code of quickconfig and of every `winrm set`. Native tools
#     ignore $ErrorActionPreference, so unchecked they fail silently.
#   - WinRM is Running, start mode is Auto, at least one listener exists, and
#     Test-WSMan succeeds (5 attempts, 3s apart, then a final throwing
#     attempt). Configured-but-not-answering is the 90-minute-timeout case;
#     Running-but-Manual is a captured template with no listener after reboot.
#   - All seven WSMan values read back equal what was set. Exit code 0 only
#     says the tool ran; these say the settings are in effect, and GPO or a
#     mistyped config path can silently win.
#   - AutoLogonCount reads back as 0.
#   - The NewNetworkWindowOff registry key exists after creation.
#   - Whether "Network Discovery" rules are still enabled after the netsh
#     call - checked, reported, but not enforced (see LOUD SKIP).
#
# FAILURE CONTRACT
#   FATAL     : profiles still unidentified after 5 minutes; any profile left
#               non-Private; netsh firewall-off returning non-zero or any
#               profile still enabled; any non-zero `winrm` exit code; WinRM
#               not Running, start mode not Auto, zero listeners, or
#               Test-WSMan never succeeding; any of the seven WSMan values
#               reading back wrong; AutoLogonCount not 0; NewNetworkWindowOff
#               key missing. All exit 1.
#   LOUD SKIP : disabling the "Network Discovery" rule group. Both a non-zero
#               netsh exit (most likely a localised group name on a non-
#               English image, so nothing matched) and a "netsh said ok but
#               rules are still enabled" read-back print a banner plus a
#               Write-Warning and continue. Acceptable because the Windows
#               firewall is already fully OFF, making this step cosmetic - but
#               the consequence is real: the "Network Discovery" rule group is
#               then still ENABLED in the captured image.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the
#           failure is readable before Packer destroys the VM. Unset: exit
#           immediately.
#
# NOTES
#   - WARNING: THIS SCRIPT LEAVES THE WINDOWS FIREWALL COMPLETELY OFF.
#     `netsh advfirewall set allprofiles state off` is applied to every
#     profile and is NEVER re-enabled here. That is intentional for the build
#     phase (it keeps WinRM reachable while provisioning), but any template
#     that runs this script MUST re-enable the firewall before it is captured
#     - e.g. with a dedicated provisioner step - or every clone ships with the
#     firewall disabled.
#   - Profiles are set via the pipeline rather than -Name: with multiple NICs,
#     -Name $profiles.Name binds an array (or the wrong single adapter) and
#     either errors or silently leaves other adapters Public.
#   - The WinRM block overlaps 01-enable-winrm.ps1 and adds two settings
#     (MaxMemoryPerShellMB, MaxConcurrentOperationsPerUser); unlike that
#     script it does not create the Packer WinRM firewall rules, because the
#     firewall is off by this point.
#   - AutoLogonCount is reset because of a documented Windows unattend issue;
#     the reference link is in the inline comment at that step.
#   - The success `exit 0` lives INSIDE the try on purpose: Packer runs this
#     as `... ; exit $LastExitCode`, so falling off the end would hand the
#     build's verdict to a stale $LASTEXITCODE from the last native call, and
#     placing it after the try/catch would mask a caught failure. `exit` still
#     runs the finally, so the transcript is closed.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path 'C:/Install/12-prepwork.txt' -Append

function Confirm-NativeExitCode {
    # Native executables (netsh, winrm, reg, ...) ignore $ErrorActionPreference,
    # so their exit codes must be checked explicitly or failures pass silently.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int[]]$AllowedExitCode = @(0)
    )
    if ($AllowedExitCode -notcontains $LASTEXITCODE) {
        throw "'$Command' failed with exit code $LASTEXITCODE"
    }
}

function Assert-WSManSetting {
    # `winrm set` exiting 0 is not proof the value stuck (GPO can win, and a
    # mistyped config path is accepted by some builds). Read it back off the
    # live WSMan configuration and fail if it is not what we asked for.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = [string](Get-Item -Path $Path -ErrorAction Stop).Value
    if ($actual -ne $Expected) {
        throw "WSMan setting '$Path' read back as '$actual', expected '$Expected'"
    }
    Write-Host "  verified $Path = $actual"
}

try {
    # Switch network connection to private mode.
    # Required for WinRM firewall rules.
    Write-Host "Switching network connection(s) to private mode"

    # Bounded wait: a NIC that never leaves "Identifying..." must fail the build
    # loudly rather than hang the provisioner forever.
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $profiles = @(Get-NetConnectionProfile)
        if ($profiles.Count -gt 0 -and -not ($profiles | Where-Object { $_.Name -eq "Identifying..." })) {
            break
        }
        if ((Get-Date) -gt $deadline) {
            $names = ($profiles | ForEach-Object { $_.Name }) -join ', '
            throw "Network connection profile(s) still not identified after 5 minutes (names: '$names')"
        }
        Start-Sleep -Seconds 10
    }

    # Pipe rather than -Name: with multiple NICs, -Name $profiles.Name binds an
    # array (or the wrong single adapter) and either errors or silently leaves
    # other adapters Public.
    $profiles |
        Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' } |
        Set-NetConnectionProfile -NetworkCategory Private

    # Read back: assert every non-domain profile really is Private now.
    $notPrivate = @(Get-NetConnectionProfile |
            Where-Object { $_.NetworkCategory -ne 'Private' -and $_.NetworkCategory -ne 'DomainAuthenticated' })
    if ($notPrivate.Count -gt 0) {
        $bad = ($notPrivate | ForEach-Object { "$($_.Name)=$($_.NetworkCategory)" }) -join ', '
        throw "Network profile(s) not set to Private: $bad"
    }
    Write-Host "Network profile(s) verified Private"

    # Drop the firewall while building; see the WARNING in the header - nothing
    # in this script turns it back on.
    Write-Host "Disabling Windows firewall (stays OFF - see script header)"
    netsh Advfirewall set allprofiles state off
    Confirm-NativeExitCode -Command 'netsh advfirewall set allprofiles state off'
    $stillOn = @(Get-NetFirewallProfile | Where-Object { $_.Enabled -eq 'True' })
    if ($stillOn.Count -gt 0) {
        throw "Firewall still enabled for profile(s): $(($stillOn | ForEach-Object { $_.Name }) -join ', ')"
    }

    # Enable WinRM service
    Write-Host "Enabling WinRM service"
    winrm quickconfig -quiet
    Confirm-NativeExitCode -Command 'winrm quickconfig'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/service AllowUnencrypted'
    winrm set winrm/config/service/auth '@{Basic="true"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/service/auth Basic'
    winrm set winrm/config/client/auth '@{Basic="true"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/client/auth Basic'
    winrm set winrm/config '@{MaxTimeoutms="7200000"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config MaxTimeoutms'
    winrm set winrm/config/winrs '@{IdleTimeout="7200000"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/winrs IdleTimeout'
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/winrs MaxMemoryPerShellMB'
    winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="12000"}'
    Confirm-NativeExitCode -Command 'winrm set winrm/config/service MaxConcurrentOperationsPerUser'

    # Making double sure WinRM service is set to auto.
    Stop-Service WinRM
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service WinRM

    # Verify the effect: a WinRM that is configured but not answering is exactly
    # the failure that shows up as a 90-minute Packer connect timeout.
    $winrmSvc = Get-Service -Name WinRM
    if ($winrmSvc.Status -ne 'Running') {
        throw "WinRM service is not Running after configuration (status: $($winrmSvc.Status))"
    }
    # Start mode too: Running now but Manual on the next boot means the captured
    # template has no listener, which nothing in this build would ever notice.
    $winrmStartMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='WinRM'").StartMode
    if ($winrmStartMode -ne 'Auto') {
        throw "WinRM start mode read back as '$winrmStartMode', expected 'Auto'"
    }
    $listeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop)
    if ($listeners.Count -eq 0) {
        throw "WinRM has no listeners configured"
    }
    # Short retry: the listener can need a moment after Start-Service. This is a
    # gate, not a courtesy - it throws once the attempts are exhausted.
    $wsmanOk = $false
    for ($i = 0; $i -lt 5; $i++) {
        try { Test-WSMan -ErrorAction Stop | Out-Null; $wsmanOk = $true; break }
        catch { Start-Sleep -Seconds 3 }
    }
    if (-not $wsmanOk) { Test-WSMan -ErrorAction Stop | Out-Null }
    Write-Host "WinRM verified: service Running, start mode $winrmStartMode, $($listeners.Count) listener(s), Test-WSMan OK"

    # Read every `winrm set` above back off the live configuration. Exit code 0
    # only says the tool ran; these assertions say the settings are in effect.
    Write-Host "Verifying WinRM configuration values"
    Assert-WSManSetting -Path 'WSMan:\localhost\Service\AllowUnencrypted' -Expected 'true'
    Assert-WSManSetting -Path 'WSMan:\localhost\Service\Auth\Basic' -Expected 'true'
    Assert-WSManSetting -Path 'WSMan:\localhost\Client\Auth\Basic' -Expected 'true'
    Assert-WSManSetting -Path 'WSMan:\localhost\MaxTimeoutms' -Expected '7200000'
    Assert-WSManSetting -Path 'WSMan:\localhost\Shell\IdleTimeout' -Expected '7200000'
    Assert-WSManSetting -Path 'WSMan:\localhost\Shell\MaxMemoryPerShellMB' -Expected '2048'
    Assert-WSManSetting -Path 'WSMan:\localhost\Service\MaxConcurrentOperationsPerUser' -Expected '12000'

    # Reset auto logon count
    # https://docs.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue
    Write-Host "Enabling initial auto login"
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoLogonCount -Value 0
    $autoLogonCount = (Get-ItemProperty -Path $winlogon -Name AutoLogonCount).AutoLogonCount
    if ($autoLogonCount -ne 0) {
        throw "AutoLogonCount read back as '$autoLogonCount', expected 0"
    }

    # Disable Network Discovery
    Write-Host "Disabling network discovery"
    $netKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff'
    New-Item -Path $netKey -Force | Out-Null
    if (-not (Test-Path -LiteralPath $netKey)) {
        throw "Failed to create $netKey"
    }

    # Firewall rule group tweak. Optional: the firewall is already fully off
    # above, so this is cosmetic, and the group name is localised on non-English
    # images. Warn loudly rather than failing the build over it.
    netsh advfirewall firewall set rule group="Network Discovery" new enable=No
    $ndExit = $LASTEXITCODE
    if ($ndExit -ne 0) {
        Write-Host "########################################################"
        Write-Host "## OPTIONAL STEP SKIPPED - NOT DONE, NOT A SUCCESS:"
        Write-Host "##   netsh advfirewall firewall set rule"
        Write-Host "##     group=`"Network Discovery`" new enable=No"
        Write-Host "##   returned exit code $ndExit."
        Write-Host "## Most likely cause: the rule group name is localised on"
        Write-Host "## this image, so nothing matched."
        Write-Host "## Left as-is on purpose: the Windows firewall is already"
        Write-Host "## fully OFF (see the header), so this step is cosmetic and"
        Write-Host "## must not fail the build. The 'Network Discovery' rule"
        Write-Host "## group is therefore still ENABLED in the captured image."
        Write-Host "########################################################"
        Write-Warning "OPTIONAL STEP SKIPPED: 'Network Discovery' rule group not disabled (netsh exit $ndExit); see the block above."
    }
    else {
        # Verify the effect rather than trusting exit 0: netsh reports success
        # for a group match that changed nothing.
        $ndStillOn = @(Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -eq 'True' })
        if ($ndStillOn.Count -gt 0) {
            Write-Host "########################################################"
            Write-Host "## OPTIONAL STEP DID NOT TAKE EFFECT:"
            Write-Host "##   netsh reported success but $($ndStillOn.Count) 'Network"
            Write-Host "##   Discovery' rule(s) are still enabled."
            Write-Host "## Not failing the build: the firewall is off anyway."
            Write-Host "########################################################"
            Write-Warning "OPTIONAL STEP DID NOT TAKE EFFECT: $($ndStillOn.Count) 'Network Discovery' rule(s) still enabled."
        }
        else {
            Write-Host "Network Discovery rule group verified disabled"
        }
    }

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE the last native call left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "12-prepwork FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    # Optional hold so the failure is readable before Packer destroys the VM.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    # Non-zero so the provisioner fails; the finally below still closes the
    # transcript. Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
