###############################################################################
# Name:             24-configure-winrm-for-ansible.ps1
# Description:      Adds everything a CLONE needs for Ansible on top of the
#                   plain HTTP WinRM that 01-enable-winrm.ps1 already set up:
#                   an HTTPS listener on 5986 with a self-signed certificate,
#                   the matching firewall rule, and CredSSP server auth.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHY THIS SCRIPT EXISTS IN THIS SHAPE
#
# WinRM is configured by exactly two scripts, split by WHEN they run and WHO
# they serve. That split is deliberate and is not a candidate for merging:
#
#   01-enable-winrm.ps1  - runs at FIRST LOGON from the bootstrap CD, before
#                          Packer can connect to anything. It configures the
#                          minimum Packer itself needs: HTTP/5985, Basic auth,
#                          AllowUnencrypted, long timeouts, service Automatic
#                          and Running. If it fails, the build cannot proceed
#                          at all, so it lives on the CD and is verified hard.
#
#   24-configure-winrm-for-ansible.ps1 (this file) - runs as a PROVISIONER,
#                          long after Packer is connected. Everything here is
#                          for the CLONE, not for the build: HTTPS, CredSSP.
#                          A failure here means a less usable template, not a
#                          failed connection.
#
# This file replaces two previous scripts:
#
#   24-ConfigureRemotingForAnsible.ps1 - the ~430-line upstream Ansible helper.
#     It was written for the PowerShell 3 / Server 2008 era, wrote to the
#     Windows event log, verified almost nothing, and duplicated work
#     01-enable-winrm.ps1 already does (Basic auth, and a SECOND firewall rule
#     for 5986 created via `netsh` under a different name than the one 01
#     creates - two rules, same port). Only its HTTPS listener and certificate
#     were actually load-bearing, and both are a handful of lines on Server
#     2016+ where New-SelfSignedCertificate exists.
#
#   25-ansible-winrm-enablecredssp.ps1 - a single Enable-WSManCredSSP call.
#     The upstream script above already had an -EnableCredSSP switch that does
#     the identical thing, but Packer runs `scripts = [...]` entries with no
#     arguments, so it could never fire. Two scripts, one capability, neither
#     aware of the other.
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\24-configure-winrm-for-ansible.txt.
#   2. Ensures Basic auth is enabled on the WinRM service (Ansible's basic
#      transport needs it; 01 also sets this - see NOTES on why that is kept).
#   3. Creates a self-signed certificate for the current hostname if no usable
#      one exists, in LocalMachine\My with a Server Authentication EKU.
#   4. Removes any existing HTTPS listener and creates one bound to that
#      certificate, so re-running converges instead of erroring on a duplicate.
#   5. Creates (replacing any existing) the Ansible-WinRM-HTTPS firewall rule
#      for inbound TCP 5986.
#   6. Enables CredSSP for the server role.
#   7. Installs C:\ProgramData\WinRM-CertRefresh\Update-WinRmCertificate.ps1
#      and registers the 'WinRM-Certificate-Refresh' scheduled task to run it
#      as SYSTEM at every startup, so a renamed clone reissues its own
#      certificate and rebinds the listener (see NOTES).
#
# WHAT IT VERIFIES
#   - Basic auth reads back as true from WSMan:\localhost\Service\Auth\Basic.
#   - The certificate exists in LocalMachine\My, has a private key, has the
#     Server Authentication EKU and is not expired. A listener bound to a
#     certificate without a private key answers TCP and then fails the TLS
#     handshake - green port, dead service, which is the exact failure mode
#     this repo has been bitten by before.
#   - An HTTPS listener exists, is Enabled, is on port 5986 and carries the
#     thumbprint of that certificate.
#   - The firewall rule exists, is Enabled, Inbound, Allow, TCP and 5986.
#   - CredSSP reads back as true.
#   - WinRM is Running and StartType Automatic, because all of the above is
#     meaningless on a service a clone will not start.
#   - The refresh script was written to disk and the scheduled task is
#     registered and not Disabled. A rename-healing mechanism that silently
#     failed to install would leave clones presenting the build certificate
#     while the log claimed otherwise.
#   NOT verified: that a remote Ansible client can actually authenticate, and
#   that the refresh task does the right thing on a real rename. No client
#   exists in the guest to test with, and the rename only happens on a clone -
#   so the refresh path is exercised by cloning the template, not by the build.
#
# FAILURE CONTRACT
#   FATAL     : any of the verifications above failing, or the certificate or
#               listener not being creatable. Exits 1 and fails the build - a
#               template whose HTTPS listener is half-configured is worse than
#               one that plainly has none, because it looks finished.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the VM can
#           be inspected before Packer destroys it. Unset: exit immediately.
#
# NOTES
#   - HOSTNAME HANDLING (the reason step 7 exists): the certificate created
#     during the build is issued for the BUILD hostname. Cloudbase-Init renames
#     the clone, at which point that CN is wrong and any Ansible connection
#     doing real certificate validation fails. Baking an HTTPS listener into an
#     image has this problem inherently - the upstream script had it too and
#     never mentioned it. Rather than telling callers to pass
#     server_cert_validation=ignore, the template now heals itself: a startup
#     task compares the listener certificate's CN against the machine name and
#     reissues plus rebinds when they differ.
#     It is a STARTUP task, not a first-boot hook, deliberately: the rename
#     happens after first boot begins and usually forces a reboot, so
#     "run once at first boot" can run before the new name exists. A converging
#     check is a no-op on every subsequent boot and also survives any LATER
#     rename. Cloudbase-Init's LocalScriptsPlugin is not enabled in this
#     image's config, so that hook would have meant changing
#     60-install-cloudbase-init.ps1 too.
#     The refresh writes C:\ProgramData\WinRM-CertRefresh\refresh.log, which
#     is where to look if a clone's certificate is not what you expect.
#   - The certificate is SELF-SIGNED and deliberately not issued by the lab CA
#     (step-ca). Chaining to the lab CA would need enrolment at clone time,
#     which is a first-boot job, not a build-time one. 11-install-lab-ca.ps1
#     installs the CA so the guest TRUSTS the lab; it does not give the guest
#     an identity.
#   - Basic auth is set here as well as in 01-enable-winrm.ps1 on purpose. The
#     two scripts have different lifetimes: 01 must stand alone on the
#     bootstrap CD for Packer, and this one must stand alone for a clone even
#     if the bootstrap path changes. Setting an idempotent value twice is
#     cheaper than a hidden ordering dependency between them.
#   - 01-enable-winrm.ps1 deliberately does NOT open 5986. It used to, which
#     meant the build opened a port for a listener that did not exist yet and
#     then this script opened it again under a different rule name. Port 5986
#     is owned here, together with the listener that justifies it.
#   - CredSSP ships ENABLED on the resulting template. It exists for Ansible's
#     credssp transport and second-hop delegation. Modern Ansible can often use
#     ntlm/kerberos/psrp instead; if this lab never needs delegation, dropping
#     this step reduces the credential-delegation surface of every clone.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$certStore = 'Cert:\LocalMachine\My'
$serverAuthOid = '1.3.6.1.5.5.7.3.1'     # Server Authentication EKU
$firewallRuleName = 'Ansible-WinRM-HTTPS'
$httpsPort = 5986
$refreshDir = 'C:\ProgramData\WinRM-CertRefresh'
$refreshScript = Join-Path $refreshDir 'Update-WinRmCertificate.ps1'
$refreshTaskName = 'WinRM-Certificate-Refresh'

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/24-configure-winrm-for-ansible.txt' -Append

function Assert-WSManSetting {
    # Read a WSMan value back off the live configuration and compare it. The
    # cmdlet returning is not evidence the setting stuck.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $actual = (Get-Item -Path $Path -ErrorAction Stop).Value
    if ("$actual" -ne "$Expected") {
        throw "WSMan setting '$Path' read back as '$actual', expected '$Expected'"
    }
    Write-Host "  verified $Path = $actual"
}

function Get-WinRmServerCertificate {
    # Reuse a usable certificate if one is already present, otherwise make one.
    # "Usable" is the important word: it must have a private key (a listener
    # bound to a certificate without one accepts the TCP connection and then
    # fails the TLS handshake - a green port in front of a dead service), the
    # Server Authentication EKU, and a validity window covering now.
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param([Parameter(Mandatory = $true)][string]$DnsName)

    $now = Get-Date
    $existing = @(Get-ChildItem -Path $certStore -ErrorAction SilentlyContinue | Where-Object {
            $_.Subject -eq "CN=$DnsName" -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt $now -and
            $_.NotBefore -le $now -and
            ($_.EnhancedKeyUsageList.ObjectId -contains $serverAuthOid)
        })

    if ($existing.Count -gt 0) {
        $cert = $existing[0]
        Write-Host "Reusing existing certificate $($cert.Thumbprint) (expires $($cert.NotAfter))"
        return $cert
    }

    Write-Host "Creating a self-signed certificate for CN=$DnsName"
    $cert = New-SelfSignedCertificate -DnsName $DnsName -CertStoreLocation $certStore `
        -KeyExportPolicy Exportable -KeyLength 2048 -NotAfter $now.AddYears(5) `
        -Provider 'Microsoft RSA SChannel Cryptographic Provider'

    # Prove it landed usable rather than trusting the cmdlet.
    $check = Get-Item -Path (Join-Path $certStore $cert.Thumbprint) -ErrorAction Stop
    if (-not $check.HasPrivateKey) {
        throw "Created certificate $($cert.Thumbprint) has no private key; a listener bound to it would fail every TLS handshake"
    }
    if ($check.EnhancedKeyUsageList.ObjectId -notcontains $serverAuthOid) {
        throw "Created certificate $($cert.Thumbprint) lacks the Server Authentication EKU"
    }
    Write-Host "Created certificate $($cert.Thumbprint) (expires $($check.NotAfter))"
    return $check
}

function Install-CertificateRefreshTask {
    # Install a startup task that reissues the WinRM certificate whenever it no
    # longer matches the machine's name, and rebinds the HTTPS listener to it.
    #
    # WHY THIS IS NEEDED: the certificate created at build time carries the
    # BUILD hostname. Cloudbase-Init's SetHostNamePlugin renames the clone on
    # first boot, at which point the CN no longer matches and any Ansible
    # connection doing real certificate validation fails. Without this, HTTPS on
    # a clone only works with server_cert_validation=ignore, which makes having
    # a certificate close to pointless.
    #
    # WHY A STARTUP TASK RATHER THAN A FIRST-BOOT HOOK: the rename happens
    # AFTER first boot begins and usually triggers a reboot, so "run once on
    # first boot" can easily run before the new name exists. A startup task
    # converges instead: it is a no-op when the CN already matches, and fixes it
    # on the very next boot when it does not. It also survives any later rename,
    # not just the one Cloudbase-Init performs. Cloudbase-Init's
    # LocalScriptsPlugin is NOT enabled in this image's config, so that hook
    # would have required changing 60-install-cloudbase-init.ps1 as well.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDirectory,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    New-Item -ItemType Directory -Force -Path $ScriptDirectory | Out-Null

    # Single-quoted here-string: nothing below is expanded at write time, it is
    # evaluated on the guest at boot. $Port is injected afterwards.
    $payload = @'
###############################################################################
# Update-WinRmCertificate.ps1 - installed by 24-configure-winrm-for-ansible.ps1
#
# Runs at every startup as SYSTEM. If the WinRM HTTPS listener's certificate
# does not match this machine's current name, issue a new self-signed
# certificate and rebind the listener to it. A no-op when they already match,
# so the cost on a normal boot is a few milliseconds.
#
# This exists because a template's certificate carries the BUILD hostname;
# clones are renamed by Cloudbase-Init and would otherwise present a
# certificate for the wrong name to every Ansible connection.
###############################################################################
$ErrorActionPreference = 'Stop'
$logDir = 'C:\ProgramData\WinRM-CertRefresh'
$log = Join-Path $logDir 'refresh.log'
$httpsPort = __HTTPS_PORT__
$serverAuthOid = '1.3.6.1.5.5.7.3.1'

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    try { Add-Content -LiteralPath $log -Value $line -ErrorAction Stop } catch { }
}

try {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $hostName = $env:COMPUTERNAME

    $listener = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop |
            Where-Object { $_.Keys -contains 'Transport=HTTPS' })

    if ($listener.Count -eq 1) {
        $path = "WSMan:\localhost\Listener\$($listener[0].Name)"
        $thumb = ((Get-Item -Path "$path\CertificateThumbprint").Value) -replace '\s', ''
        $bound = Get-ChildItem -Path Cert:\LocalMachine\My |
            Where-Object { $_.Thumbprint -eq $thumb }
        if ($bound -and $bound.Subject -eq "CN=$hostName" -and $bound.NotAfter -gt (Get-Date)) {
            Write-Log "OK: listener certificate already matches CN=$hostName ($thumb); nothing to do."
            exit 0
        }
        Write-Log "Certificate does not match: listener has '$($bound.Subject)', machine is '$hostName'. Reissuing."
    }
    elseif ($listener.Count -eq 0) {
        Write-Log "No HTTPS listener present; creating one for CN=$hostName."
    }
    else {
        Write-Log "Found $($listener.Count) HTTPS listeners; collapsing to one for CN=$hostName."
    }

    $cert = New-SelfSignedCertificate -DnsName $hostName -CertStoreLocation 'Cert:\LocalMachine\My' `
        -KeyExportPolicy Exportable -KeyLength 2048 -NotAfter (Get-Date).AddYears(5) `
        -Provider 'Microsoft RSA SChannel Cryptographic Provider'

    $check = Get-Item -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)"
    if (-not $check.HasPrivateKey) { throw "new certificate $($cert.Thumbprint) has no private key" }
    if ($check.EnhancedKeyUsageList.ObjectId -notcontains $serverAuthOid) {
        throw "new certificate $($cert.Thumbprint) lacks the Server Authentication EKU"
    }

    foreach ($old in @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
                Where-Object { $_.Keys -contains 'Transport=HTTPS' })) {
        Remove-Item -Path "WSMan:\localhost\Listener\$($old.Name)" -Recurse -Force
    }
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
        -CertificateThumbPrint $cert.Thumbprint -Port $httpsPort -Force | Out-Null

    # Verify the rebind rather than trusting it.
    $after = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop |
            Where-Object { $_.Keys -contains 'Transport=HTTPS' })
    if ($after.Count -ne 1) { throw "expected 1 HTTPS listener after rebind, found $($after.Count)" }
    $afterPath = "WSMan:\localhost\Listener\$($after[0].Name)"
    $afterThumb = ((Get-Item -Path "$afterPath\CertificateThumbprint").Value) -replace '\s', ''
    if ($afterThumb -ne $cert.Thumbprint) {
        throw "listener bound to '$afterThumb', expected '$($cert.Thumbprint)'"
    }
    Write-Log "Reissued for CN=$hostName and rebound listener to $($cert.Thumbprint)."
    exit 0
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
'@

    $payload = $payload.Replace('__HTTPS_PORT__', "$Port")
    Set-Content -LiteralPath $ScriptPath -Value $payload -Encoding ASCII -Force

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Failed to write the certificate refresh script to $ScriptPath"
    }

    # Re-register cleanly so a rebuild converges instead of erroring.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null

    # Verify the task actually registered and is enabled.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { throw "Scheduled task '$TaskName' is not registered after Register-ScheduledTask" }
    if ($task.State -eq 'Disabled') { throw "Scheduled task '$TaskName' registered but is Disabled" }
    Write-Host "  verified scheduled task '$TaskName' registered (state: $($task.State))"
}

try {
    # ---- Basic auth (Ansible's basic transport) --------------------------------
    Write-Host "Enabling Basic authentication on the WinRM service"
    Set-Item -Path 'WSMan:\localhost\Service\Auth\Basic' -Value $true -Force
    Assert-WSManSetting -Path 'WSMan:\localhost\Service\Auth\Basic' -Expected 'true'

    # ---- Certificate -----------------------------------------------------------
    $hostName = $env:COMPUTERNAME
    $cert = Get-WinRmServerCertificate -DnsName $hostName

    # ---- HTTPS listener --------------------------------------------------------
    # Remove first so a re-run converges instead of failing on "already exists",
    # and so a listener left bound to a stale certificate cannot survive.
    $existingListeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
            Where-Object { $_.Keys -contains 'Transport=HTTPS' })
    foreach ($listener in $existingListeners) {
        Write-Host "Removing existing HTTPS listener $($listener.Name)"
        Remove-Item -Path "WSMan:\localhost\Listener\$($listener.Name)" -Recurse -Force
    }

    Write-Host "Creating the HTTPS listener on port $httpsPort"
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
        -CertificateThumbPrint $cert.Thumbprint -Port $httpsPort -Force | Out-Null

    # ---- Firewall --------------------------------------------------------------
    # Stable -Name, replace-then-create: idempotent, and never accumulates the
    # duplicate rules that `netsh advfirewall add rule` used to leave behind.
    if (Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue) {
        Write-Host "Replacing existing firewall rule '$firewallRuleName'"
        Remove-NetFirewallRule -Name $firewallRuleName -ErrorAction Stop
    }
    else {
        Write-Host "Creating firewall rule '$firewallRuleName'"
    }
    New-NetFirewallRule -Name $firewallRuleName -DisplayName 'Allow WinRM HTTPS (Ansible)' `
        -Direction Inbound -Action Allow -Enabled True -Profile Any `
        -Protocol TCP -LocalPort $httpsPort | Out-Null

    # ---- CredSSP ---------------------------------------------------------------
    Write-Host "Enabling CredSSP for the server role"
    Enable-WSManCredSSP -Role Server -Force | Out-Null

    # ---- First-boot / rename self-healing --------------------------------------
    Write-Host "Installing the certificate refresh task"
    Install-CertificateRefreshTask -ScriptDirectory $refreshDir -ScriptPath $refreshScript `
        -TaskName $refreshTaskName -Port $httpsPort

    # ---- Verify the whole result, not the individual calls ---------------------
    Write-Host ""
    Write-Host "Verifying the end state"

    $httpsListener = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop |
            Where-Object { $_.Keys -contains 'Transport=HTTPS' })
    if ($httpsListener.Count -ne 1) {
        throw "Expected exactly 1 HTTPS listener, found $($httpsListener.Count)"
    }

    $listenerPath = "WSMan:\localhost\Listener\$($httpsListener[0].Name)"
    $listenerPort = (Get-Item -Path "$listenerPath\Port" -ErrorAction Stop).Value
    $listenerCert = (Get-Item -Path "$listenerPath\CertificateThumbprint" -ErrorAction Stop).Value
    $listenerOn = (Get-Item -Path "$listenerPath\Enabled" -ErrorAction Stop).Value

    if ("$listenerPort" -ne "$httpsPort") {
        throw "HTTPS listener is on port '$listenerPort', expected $httpsPort"
    }
    if ("$listenerOn" -ne 'true') {
        throw "HTTPS listener exists but is not enabled (Enabled=$listenerOn)"
    }
    if (($listenerCert -replace '\s', '') -ne $cert.Thumbprint) {
        throw "HTTPS listener is bound to thumbprint '$listenerCert', expected '$($cert.Thumbprint)'"
    }
    Write-Host "  verified HTTPS listener: port $listenerPort, enabled, thumbprint $($cert.Thumbprint)"

    $rule = Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
    if (-not $rule) { throw "Firewall rule '$firewallRuleName' missing after create" }
    if ("$($rule.Enabled)" -ne 'True') {
        throw "Firewall rule '$firewallRuleName' is not enabled (Enabled=$($rule.Enabled))"
    }
    if ("$($rule.Direction)" -ne 'Inbound') {
        throw "Firewall rule '$firewallRuleName' direction is '$($rule.Direction)', expected Inbound"
    }
    if ("$($rule.Action)" -ne 'Allow') {
        throw "Firewall rule '$firewallRuleName' action is '$($rule.Action)', expected Allow"
    }
    $filter = $rule | Get-NetFirewallPortFilter
    if ("$($filter.Protocol)" -ne 'TCP') {
        throw "Firewall rule '$firewallRuleName' protocol is '$($filter.Protocol)', expected TCP"
    }
    if ("$($filter.LocalPort)" -ne "$httpsPort") {
        throw "Firewall rule '$firewallRuleName' local port is '$($filter.LocalPort)', expected $httpsPort"
    }
    Write-Host "  verified firewall rule '$firewallRuleName': Inbound Allow TCP $httpsPort, enabled"

    Assert-WSManSetting -Path 'WSMan:\localhost\Service\Auth\CredSSP' -Expected 'true'

    # All of the above is meaningless on a service a clone will not start.
    $winrm = Get-Service -Name WinRM -ErrorAction Stop
    if ($winrm.Status -ne 'Running') {
        throw "WinRM is '$($winrm.Status)', so this configuration is on a service that is not serving"
    }
    if ($winrm.StartType -ne 'Automatic') {
        throw "WinRM StartType is '$($winrm.StartType)', expected Automatic - clones would boot without WinRM"
    }
    Write-Host "  verified WinRM service: $($winrm.Status), StartType $($winrm.StartType)"

    Write-Host ""
    Write-Host "WinRM is configured for Ansible: HTTPS on $httpsPort, Basic and CredSSP auth."
    Write-Host "The build-time certificate is issued for '$hostName'. A clone renamed by"
    Write-Host "Cloudbase-Init gets a fresh certificate for its own name at next startup,"
    Write-Host "via the '$refreshTaskName' scheduled task, so Ansible can validate it."

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to a stale $LASTEXITCODE, and placing it after the try/catch would
    # mask a caught failure. `exit` still runs the finally below.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "24-configure-winrm-for-ansible FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
