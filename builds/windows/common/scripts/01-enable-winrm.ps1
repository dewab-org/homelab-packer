###############################################################################
# Name:             01-enable-winrm.ps1
# Description:      Minimal WinRM enablement for Packer provisioning: run
#                   quickconfig, apply five WSMan settings, open TCP 5985 in
#                   the firewall, then prove WinRM actually answers.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Windows\Temp\01-enable-winrm.txt (append).
#   2. Runs `winrm quickconfig -quiet`.
#   3. Applies five settings with `winrm set`: service AllowUnencrypted=true,
#      service auth Basic=true, client auth Basic=true, MaxTimeoutms=7200000,
#      winrs IdleTimeout=7200000.
#   4. Bounces the service: best-effort Stop-Service, then Set-Service
#      -StartupType Automatic and Start-Service.
#   5. Creates (replacing any existing) one inbound firewall rule by stable
#      -Name: Packer-WinRM-HTTP, TCP 5985.
#   6. Asserts the end state, then reads every `winrm set` value back off the
#      live WSMan configuration.
#
# WHAT IT VERIFIES
#   - Exit code of `winrm quickconfig` and of every `winrm set`. Native tools
#     ignore $ErrorActionPreference, so unchecked they fail silently.
#   - The firewall rule exists after create and is Enabled, Inbound, Allow,
#     protocol TCP, on port 5985. Failure means Packer cannot reach the
#     listener even when it is up.
#   - WinRM service is Running. Failure is the 90-minute-timeout case.
#   - WinRM start mode is Auto. Failure means Running now but no listener
#     after reboot - a captured template nothing later would notice.
#   - At least one WSMan listener is configured.
#   - Test-WSMan succeeds (5 attempts, 3s apart, then one final throwing
#     attempt). Failure means configured-but-not-answering.
#   - All five WSMan values read back equal what was set. Exit code 0 only
#     says the tool ran; these say the settings are in effect.
#
# FAILURE CONTRACT
#   FATAL     : any failed native exit code, any firewall-rule assertion, a
#               non-Running service, a start mode other than Auto, zero
#               listeners, a Test-WSMan that never succeeds, or any WSMan
#               value that reads back wrong. All exit 1 so the caller fails
#               fast instead of waiting out a 90-minute Packer WinRM timeout.
#   LOUD SKIP : Stop-Service WinRM failing before the restart prints a banner
#               and continues. Acceptable because `winrm set` applies live and
#               the required end state (Running + listener + Test-WSMan) is
#               asserted below regardless, and will fail the script if unmet.
#
# NOTES
#   - This is the script whose silent failure costs 90 minutes: every step
#     used to be an unchecked native `winrm`/`netsh` call, so a failed
#     quickconfig left the build "Waiting for WinRM to become available..."
#     until Packer timed out.
#   - The firewall rule is keyed by a stable -Name specifically so re-running
#     the bootstrap does not pile up duplicate "Allow WinRM HTTP" rules the
#     way `netsh advfirewall add rule` did. It is removed and recreated rather
#     than updated in place: piping a rule object into Set-NetFirewallRule
#     alongside -DisplayName cannot bind, and under EAP=Stop that took the
#     whole script down while WinRM itself was working.
#   - Unencrypted + Basic is deliberate: this is the build transport on a lab
#     VLAN, and Packer needs it before anything else exists. HTTPS, CredSSP
#     and port 5986 are NOT this script's business - they are set up later by
#     24-configure-winrm-for-ansible.ps1, which owns 5986 together with the
#     listener and certificate that justify opening it.
#   - The success `exit 0` lives INSIDE the try on purpose: Packer runs this
#     as `... ; exit $LastExitCode`, so falling off the end would hand the
#     build's verdict to a stale $LASTEXITCODE, and placing it after the
#     try/catch would mask a caught failure. `exit` still runs the finally,
#     so the transcript is closed either way.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:/Windows/Temp/01-enable-winrm.txt" -Append

function Confirm-NativeExitCode {
    # Native executables ignore $ErrorActionPreference; check them explicitly.
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
    # `winrm set` exiting 0 only says the tool ran. Read the value back off the
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

function Register-WinRmFirewallRule {
    # Idempotent by stable rule -Name: re-running the bootstrap must not pile up
    # duplicate "Allow WinRM HTTP" rules the way `netsh advfirewall add rule` did.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    # Delete-then-create rather than update-in-place. The update path used to be
    #     $existing | Set-NetFirewallRule -DisplayName ... -Direction ...
    # which cannot bind: -DisplayName is a QUERY parameter in its own parameter
    # set, so combining it with pipeline input gives
    #     "The input object cannot be bound to any parameters for the command"
    # and, under $ErrorActionPreference='Stop', took the whole script down with
    # it. That is what produced a bare "enable WinRM : exited with code 1" in
    # the bootstrap marker while WinRM itself was working fine.
    #
    # Removing and recreating sidesteps the parameter-set rules entirely and is
    # unambiguously idempotent: the stable -Name means re-running the bootstrap
    # converges on exactly one rule instead of piling up duplicates, which is
    # the behaviour this function exists to guarantee.
    $existing = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Replacing existing firewall rule '$Name'"
        Remove-NetFirewallRule -Name $Name -ErrorAction Stop
    }
    else {
        Write-Host "Creating firewall rule '$Name'"
    }
    New-NetFirewallRule -Name $Name -DisplayName $DisplayName -Direction Inbound `
        -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort $Port | Out-Null

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { throw "Firewall rule '$Name' missing after create/update" }
    if ("$($rule.Enabled)" -ne 'True') {
        throw "Firewall rule '$Name' exists but is not enabled (Enabled=$($rule.Enabled))"
    }
    if ("$($rule.Direction)" -ne 'Inbound') {
        throw "Firewall rule '$Name' has direction '$($rule.Direction)', expected Inbound"
    }
    if ("$($rule.Action)" -ne 'Allow') {
        throw "Firewall rule '$Name' has action '$($rule.Action)', expected Allow"
    }
    $filter = $rule | Get-NetFirewallPortFilter
    # Protocol is set by Set-NetFirewallPortFilter on the update path, so it is a
    # separate write from the rule itself and needs its own read-back.
    if ("$($filter.Protocol)" -ne 'TCP') {
        throw "Firewall rule '$Name' has protocol '$($filter.Protocol)', expected TCP"
    }
    if ("$($filter.LocalPort)" -ne "$Port") {
        throw "Firewall rule '$Name' has local port '$($filter.LocalPort)', expected $Port"
    }
    Write-Host "  verified rule '$Name': Inbound Allow TCP/$Port, Enabled"
}

try {
    Write-Host "Enabling WinRM service"
    winrm quickconfig -quiet
    Confirm-NativeExitCode -Command 'winrm quickconfig'

    # Homelab build: keep it simple; ConfigureRemotingForAnsible will set up HTTPS.
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

    # The stop is a best-effort bounce, not a requirement: `winrm set` applies
    # live, and the end state (Running + listener + Test-WSMan) is asserted
    # below regardless. It is still reported loudly rather than swallowed.
    $stopErr = $null
    Stop-Service WinRM -ErrorAction SilentlyContinue -ErrorVariable stopErr
    if ($stopErr) {
        Write-Host "########################################################"
        Write-Host "## OPTIONAL STEP FAILED - could not stop WinRM before"
        Write-Host "## restarting it: $($stopErr[0].Exception.Message)"
        Write-Host "## Continuing: the required end state is asserted below"
        Write-Host "## and will fail this script if it is not met."
        Write-Host "########################################################"
    }
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service WinRM

    Write-Host "Allowing WinRM through the firewall (TCP 5985)"
    # 5985 only. This script owns Packer's HTTP path and nothing else.
    #
    # It used to also open 5986, which was wrong twice over: no HTTPS listener
    # exists at this point in the build, so it opened a port for a service that
    # was not there; and 24-configure-winrm-for-ansible.ps1 later opened the
    # same port again under a different rule name, leaving two rules for one
    # port. Port 5986 is now owned by that script, together with the listener
    # and certificate that justify it.
    Register-WinRmFirewallRule -Name 'Packer-WinRM-HTTP' -DisplayName 'Allow WinRM HTTP' -Port 5985

    # Verify the effect. Configured-but-not-answering is the exact failure mode
    # this script exists to prevent, so prove it end to end before returning.
    $svc = Get-Service -Name WinRM
    if ($svc.Status -ne 'Running') {
        throw "WinRM service is not Running after configuration (status: $($svc.Status))"
    }
    # Start mode too: Running now but Manual after reboot is a template with no
    # listener, and nothing later in the build would notice.
    $startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='WinRM'").StartMode
    if ($startMode -ne 'Auto') {
        throw "WinRM start mode read back as '$startMode', expected 'Auto'"
    }
    $listeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop)
    if ($listeners.Count -eq 0) {
        throw "WinRM is running but has no listeners configured"
    }
    foreach ($l in $listeners) { Write-Host "  listener: $($l.Name)" }
    # Short retry: the listener can need a moment after Start-Service. This is a
    # gate, not a courtesy - it throws once the attempts are exhausted.
    $wsmanOk = $false
    for ($i = 0; $i -lt 5; $i++) {
        try { Test-WSMan -ErrorAction Stop | Out-Null; $wsmanOk = $true; break }
        catch { Start-Sleep -Seconds 3 }
    }
    if (-not $wsmanOk) { Test-WSMan -ErrorAction Stop | Out-Null }

    # Read every `winrm set` above back off the live configuration. Exit code 0
    # only says the tool ran; these assertions say the settings are in effect.
    # Check ALL of them and report every mismatch, rather than throwing on the
    # first. This runs at first logon inside bootstrap, where the only evidence
    # that survives is a marker file saying "exited with code 1" -- so a
    # one-at-a-time assertion costs a full ~55-minute build per value learned.
    # Windows also normalises some of these (a value can be accepted by
    # `winrm set` and stored clamped), so seeing the actual alongside the
    # expected for every setting at once is what makes that diagnosable.
    Write-Host "Verifying WinRM configuration values"
    $expected = [ordered]@{
        'WSMan:\localhost\Service\AllowUnencrypted' = 'true'
        'WSMan:\localhost\Service\Auth\Basic'       = 'true'
        'WSMan:\localhost\Client\Auth\Basic'        = 'true'
        'WSMan:\localhost\MaxTimeoutms'             = '7200000'
        'WSMan:\localhost\Shell\IdleTimeout'        = '7200000'
    }
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($path in $expected.Keys) {
        $want = $expected[$path]
        try {
            $actual = (Get-Item -Path $path -ErrorAction Stop).Value
        }
        catch {
            $mismatches.Add("$path : could not be read ($($_.Exception.Message))")
            continue
        }
        if ("$actual" -ne "$want") {
            $mismatches.Add("$path : expected '$want', read back '$actual'")
        }
        else {
            Write-Host "  ok: $path = $actual"
        }
    }
    if ($mismatches.Count -gt 0) {
        Write-Host ""
        Write-Host "WinRM configuration did not take. Every mismatch:"
        foreach ($m in $mismatches) { Write-Host "  - $m" }
        throw "WinRM configuration verification failed for $($mismatches.Count) setting(s): $($mismatches -join '; ')"
    }

    Write-Host "WinRM verified: service Running, start mode $startMode, $($listeners.Count) listener(s), Test-WSMan OK"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE the last `winrm` call left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host "Failed enabling WinRM: $($_.Exception.Message)"

    # Non-zero so the caller fails fast instead of waiting out a 90-minute
    # Packer WinRM timeout; the finally below still closes the transcript.
    # Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
