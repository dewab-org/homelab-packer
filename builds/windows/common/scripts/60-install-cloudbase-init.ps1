###############################################################################
# Name:             60-install-cloudbase-init.ps1
# Description:      Download, verify and install the Cloudbase-Init MSI, write
#                   its Proxmox configdrive2 configuration, then re-arm it by
#                   clearing the per-instance state so clones run cloud-init.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install (before the transcript, or Start-Transcript throws at
#      script scope with nothing to explain it) and starts the transcript.
#   2. Reads CLOUDBASE_INIT_URL / _CHECKSUM / _USERNAME; refuses to continue
#      without a URL or with an empty username.
#   3. Downloads the MSI to C:\Install\cloudbase-init.msi.
#   4. Verifies the checksum when one is configured.
#   5. Installs with msiexec /qn /norestart and a verbose log at
#      C:\Install\cloudbase-init-msi.log; accepts exit 0 or 3010 only.
#   6. Writes BOTH cloudbase-init.conf and cloudbase-init-unattend.conf into
#      <installdir>\conf, pointed at ConfigDriveService with cdrom lookup on.
#   7. Sets the cloudbase-init service to Automatic.
#   8. RE-ARM: stops the service, waits for it to actually reach Stopped, and
#      only then deletes every per-instance state subkey under BOTH registry
#      views (native and WOW6432Node).
#   9. Re-asserts the end state and exits 0.
#
# WHAT IT VERIFIES
#   - Downloaded file exists and is >= 1MB: a smaller file is a captive portal
#     or error page, not an MSI.
#   - Checksum matches when pinned; a checksum that cannot be PARSED is fatal,
#     because a typo'd value used to verify nothing while looking configured.
#   - msiexec exit code AND the install directory AND the registered service.
#     The exit code alone is not proof; msiexec has returned before the product
#     was registered, and an unverified install shipped a template with no
#     Cloudbase-Init at all.
#   - Both .conf files are read back from disk and asserted to contain
#     username=, config_drive_cdrom=true, first_logon_behaviour=no,
#     inject_user_password=true and the ConfigDriveService metadata_services
#     line. Writing a file is not evidence of its contents.
#   - The service reaches Stopped BEFORE any state is cleared (see NOTES).
#   - Each state key is re-queried after deletion; a survivor throws, because a
#     re-arm that did nothing must never look like one that worked.
#   - Final: StartMode=Auto (from CIM, the value the SCM acts on at next boot),
#     Status=Stopped, and no instance state in either registry view.
#
# FAILURE CONTRACT
#   FATAL     : missing CLOUDBASE_INIT_URL or empty username; failed or short
#               download; unparseable/mismatched checksum; msiexec exit other
#               than 0/3010; missing install dir or unregistered service;
#               missing conf directory or a conf file that does not read back
#               with the required settings; the service not reaching Stopped;
#               any state subkey surviving the clear or reappearing afterwards;
#               StartMode not Auto or final Status not Stopped. All of these
#               exit 1 and fail the build - a template without a working,
#               re-armed Cloudbase-Init is not a cloud image, and shipping one
#               is worse than failing.
#   LOUD SKIP : none. The only tolerated soft paths still install and
#               configure. CLOUDBASE_INIT_CHECKSUM unset or 'none' warns that
#               installer integrity is NOT verified; an absent state key in
#               both views prints a NOTE block saying nothing was re-armed and
#               that a relocated key would look exactly the same.
#
# INPUTS (environment)
#   CLOUDBASE_INIT_URL       Required. MSI download URL; set via
#                            cloudbase_init_url in the build's
#                            variables.auto.pkrvars.hcl.
#   CLOUDBASE_INIT_CHECKSUM  Optional. "algo:hex" (sha1/sha256/sha384/sha512/
#                            md5), or "none"/empty to skip deliberately.
#                            Anything else is a hard error.
#   CLOUDBASE_INIT_USERNAME  Optional. Account Cloudbase-Init creates and
#                            configures on a clone; default "Admin".
#   PACKER_DEBUG_HOLD        Optional. On failure, sleep 3600s before exiting
#                            so the VM can be inspected before Packer destroys
#                            it.
#
# NOTES
#   - Cloudbase-Init is what makes a Windows template a *cloud* image. Without
#     it the cloud-init drive Proxmox attaches is inert and a clone ignores
#     ciuser / cipassword / sshkeys / ipconfig entirely.
#   - THE RE-ARM IS THE POINT. Cloudbase-Init records which plugins it has
#     already run, keyed by instance id, under
#     HKLM\SOFTWARE\Cloudbase Solutions\Cloudbase-Init. A template carrying
#     "already done" markers produces clones that silently skip cloud-init.
#     Clearing that state is the Windows equivalent of `cloud-init clean` and
#     is exactly what the link-clone test checks.
#   - THE RE-ARM CLEARS BOTH REGISTRY VIEWS. A 64-bit PowerShell host does not
#     see a 32-bit component's keys unless WOW6432Node is probed explicitly, so
#     both the native and the WOW6432Node path are cleared and both are
#     re-read. Probing only the native view is a textbook silent no-op:
#     "nothing to re-arm" reads identically whether the state is absent or
#     merely invisible.
#   - ORDER IS LOAD-BEARING: STOP THE SERVICE, THEN CLEAR. The service is
#     Automatic by this point and can run once more on the build VM before
#     Packer seals it. Clearing while it is running leaves a window in which it
#     writes the state straight back - and the clear still reports success. The
#     clear therefore happens only after the service is confirmed Stopped, and
#     failure to reach Stopped is fatal rather than a reason to proceed.
#   - The install directory is the MSI's hardcoded default and is deliberately
#     not configurable here: changing INSTALLDIR would also have to be threaded
#     through the conf file's bsdtar/mtools/log paths. If the MSI default ever
#     moves, the Test-Path assertion fails loudly instead of shipping a broken
#     template.
#   - The configured username is CREATED by Cloudbase-Init on a clone's first
#     boot; it is not the built-in Administrator. Keep it consistent with
#     anything else in the build that provisions or renames an admin account.
#   - first_logon_behaviour=no is required. Without it the user is created with
#     "must change password", so the cloud-init password is correct but
#     immediately rejected and both remote login and WinRM fail on a fresh
#     clone even though provisioning succeeded.
#   - Only ConfigDriveService is listed: Proxmox hands cloud-init data to
#     Windows guests as a configdrive2 CD-ROM, and the stock config's HTTP/EC2
#     endpoints do not exist on this network - they only add boot delay while
#     they time out.
#   - Transcripts live in C:\Install and 998-cleanup keeps them by default;
#     deleting them is how a failed install once shipped with no explanation.

[CmdletBinding()]
param(
    [string]$Username = $(if ([string]::IsNullOrWhiteSpace($env:CLOUDBASE_INIT_USERNAME)) { 'Admin' } else { $env:CLOUDBASE_INIT_USERNAME })
)

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

# Cloudbase-Init records which plugins it has already run under this key. A
# 64-bit PowerShell host does not see a 32-bit component's keys unless the
# WOW6432Node path is probed explicitly, so BOTH views are cleared and both are
# re-read. Probing only the native view is a textbook silent no-op: "nothing to
# re-arm" reads exactly the same whether the state is absent or merely invisible.
$StateKeyPaths = @(
    'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init',
    'HKLM:\SOFTWARE\WOW6432Node\Cloudbase Solutions\Cloudbase-Init'
)

function Clear-CloudbaseInitState {
    <#
        Delete every per-instance state subkey under both registry views and
        prove it is gone by re-querying. Returns the number of subkeys removed.
        Throws if anything survives - a re-arm that did nothing must never look
        like one that worked.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $removed = 0
    $present = 0

    foreach ($stateKey in $Paths) {
        if (-not (Test-Path -Path $stateKey)) {
            Write-Host "  state key absent: $stateKey"
            continue
        }
        $present++

        foreach ($child in @(Get-ChildItem -Path $stateKey)) {
            Remove-Item -Path $child.PSPath -Recurse -Force
            Write-Host "  cleared Cloudbase-Init state: $($child.PSChildName) (under $stateKey)"
            $removed++
        }

        # Re-query: the only proof the state is gone.
        $remaining = @(Get-ChildItem -Path $stateKey)
        if ($remaining.Count -ne 0) {
            throw "Cloudbase-Init re-arm failed: $($remaining.Count) state subkey(s) still present under $stateKey ($($remaining.PSChildName -join ', ')). Clones would skip cloud-init."
        }
        Write-Host "  verified: no instance state remains under $stateKey"
    }

    if ($present -eq 0) {
        # Not an error - a fresh install that has never run the service has no
        # state at all - but it is stated plainly rather than implied, because
        # "no key found" is also what a moved/renamed key looks like.
        Write-Host "  NOTE: no Cloudbase-Init state key exists in either registry view."
        Write-Host "  NOTE: probed: $($Paths -join ' ; ')"
        Write-Host "  NOTE: nothing to re-arm. If a future Cloudbase-Init release moves this"
        Write-Host "  NOTE: key, THIS is the line that will be printed while clones silently"
        Write-Host "  NOTE: skip cloud-init - check the key location before trusting it."
    }

    return $removed
}

# Before the transcript: if C:\Install is missing, Start-Transcript throws at
# script scope and the whole run dies with no transcript explaining why.
New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null
if (-not (Test-Path -Path 'C:\Install')) {
    throw "Could not create C:\Install"
}

Start-Transcript -Path 'C:/Install/60-install-cloudbase-init.txt' -Append

try {
    $installerUrl = $env:CLOUDBASE_INIT_URL
    $checksum = $env:CLOUDBASE_INIT_CHECKSUM

    if ([string]::IsNullOrWhiteSpace($installerUrl)) {
        # Not a silent skip: a template without Cloudbase-Init is not a cloud
        # image, so fail rather than quietly producing a broken artifact.
        throw "CLOUDBASE_INIT_URL is not set. Set cloudbase_init_url in the build's variables.auto.pkrvars.hcl."
    }
    if ([string]::IsNullOrWhiteSpace($Username)) {
        throw "Cloudbase-Init username resolved to empty. Set CLOUDBASE_INIT_USERNAME or leave it unset for the 'Admin' default."
    }
    Write-Host "Cloudbase-Init will be configured for username '$Username'"

    $installerPath = 'C:\Install\cloudbase-init.msi'
    Write-Host "Downloading Cloudbase-Init from $installerUrl"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath)) {
        throw "Download reported success but $installerPath does not exist"
    }
    $installerSize = (Get-Item $installerPath).Length
    if ($installerSize -lt 1MB) {
        throw "Downloaded $installerPath is only $installerSize bytes - that is not a Cloudbase-Init MSI (captive portal or error page?)"
    }
    Write-Host "Downloaded $installerPath ($installerSize bytes)"

    # Checksum. Empty or 'none' means "deliberately unpinned"; ANY other value
    # must parse as algo:hex and must match. The previous version fell through
    # silently when the string was not algo:hex, so a typo'd checksum verified
    # nothing at all while still looking configured.
    if ([string]::IsNullOrWhiteSpace($checksum) -or $checksum -eq 'none') {
        Write-Host "WARNING: CLOUDBASE_INIT_CHECKSUM not set - installer integrity is NOT verified."
    }
    else {
        $parts = $checksum.Split(':', 2)
        if ($parts.Count -ne 2) {
            throw "CLOUDBASE_INIT_CHECKSUM ('$checksum') is not in 'algo:hex' form (e.g. 'sha256:ab12...'). Use 'none' to skip verification deliberately."
        }
        $algo = $parts[0].Trim().ToUpper()
        $expected = $parts[1].Trim().ToLower()
        $validAlgos = @('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')
        if ($validAlgos -notcontains $algo) {
            throw "CLOUDBASE_INIT_CHECKSUM algorithm '$algo' is not one of: $($validAlgos -join ', ')"
        }
        if ($expected -notmatch '^[0-9a-f]+$') {
            throw "CLOUDBASE_INIT_CHECKSUM hash '$expected' is not hexadecimal"
        }
        $actual = (Get-FileHash -Path $installerPath -Algorithm $algo).Hash.ToLower()
        if ($actual -ne $expected) {
            throw "Cloudbase-Init checksum mismatch: expected $expected, got $actual"
        }
        Write-Host "Checksum OK ($algo)"
    }

    Write-Host "Installing Cloudbase-Init"
    $log = 'C:\Install\cloudbase-init-msi.log'
    $p = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', "`"$installerPath`"", '/qn', '/norestart', '/l*v', "`"$log`"") `
        -Wait -PassThru
    Write-Host "msiexec exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {   # 3010 = success, reboot required
        throw "Cloudbase-Init installer failed with exit code $($p.ExitCode); see $log"
    }

    # Verify rather than trust the exit code - msiexec has been observed to
    # return before the product is actually registered.
    # The MSI's default INSTALLDIR, derived from the environment rather than
    # hardcoded to C: so the assertion (and the paths written into the conf
    # files below) still point at the real location on an image whose Program
    # Files is not on C:. Still deliberately not configurable - see the header.
    $installDir = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init'
    if (-not (Test-Path $installDir)) {
        throw "Cloudbase-Init reported success but $installDir does not exist"
    }
    $svc = Get-Service -Name 'cloudbase-init' -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Cloudbase-Init reported success but the cloudbase-init service is not registered"
    }
    Write-Host "Verified: $installDir present, service '$($svc.Name)' is $($svc.Status)"

    # --- configure for Proxmox -------------------------------------------
    $confDir = Join-Path $installDir 'conf'
    $conf = @"
[DEFAULT]
username=$Username
groups=Administrators
inject_user_password=true
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
; Do not force a password change at first logon. Without this Cloudbase-Init
; creates the user with "must change password", so the cloud-init password is
; correct but immediately rejected - remote login and WinRM both fail on a
; freshly cloned VM even though provisioning succeeded.
first_logon_behaviour=no
bsdtar_path=$installDir\bin\bsdtar.exe
mtu_use_dhcp_config=true
ntp_use_dhcp_config=true
logdir=$installDir\log\
logfile=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
logging_serial_port_settings=
mtools_path=$installDir\bin\
local_scripts_path=$installDir\LocalScripts\
check_latest_version=false
; Proxmox hands cloud-init data to Windows guests as a configdrive2 CD-ROM.
; Only that service is listed: the stock config also probes HTTP/EC2 metadata
; endpoints that do not exist here, which only adds boot delay.
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,
    cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,
    cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,
    cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,
    cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,
    cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,
    cloudbaseinit.plugins.common.userdata.UserDataPlugin
allow_reboot=false
stop_service_on_exit=false
"@
    New-Item -Path $confDir -ItemType Directory -Force | Out-Null
    if (-not (Test-Path -Path $confDir)) {
        throw "Could not create the Cloudbase-Init conf directory $confDir"
    }

    # The settings that actually decide whether a clone gets configured. These
    # are asserted against what is on disk afterwards - writing a file is not
    # evidence that the file contains what you meant.
    $requiredConfLines = @(
        "username=$Username",
        'config_drive_cdrom=true',
        'first_logon_behaviour=no',
        'inject_user_password=true',
        'metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService'
    )

    foreach ($f in @('cloudbase-init.conf', 'cloudbase-init-unattend.conf')) {
        $confPath = Join-Path $confDir $f
        Set-Content -Path $confPath -Value $conf -Encoding ASCII
        Write-Host "Wrote $f"

        # Read back from disk and assert.
        if (-not (Test-Path $confPath)) {
            throw "Wrote $confPath but it does not exist"
        }
        $written = Get-Content -Path $confPath -Raw
        foreach ($line in $requiredConfLines) {
            if ($written -notmatch [regex]::Escape($line)) {
                throw "$confPath is missing the expected setting '$line' after being written"
            }
        }
        Write-Host "Verified $f contains: $($requiredConfLines -join '; ')"
    }

    # The service must start on boot for a clone to be configured at all.
    Set-Service -Name 'cloudbase-init' -StartupType Automatic
    Write-Host "cloudbase-init service set to Automatic"

    # --- re-arm ------------------------------------------------------------
    # Cloudbase-Init records which plugins it has already executed, keyed by
    # instance id, under HKLM\SOFTWARE\Cloudbase Solutions\Cloudbase-Init. The
    # service is Automatic from here, so it can well run once more on this build
    # VM before packer seals it - and a template carrying "already done" state
    # produces clones that silently skip configuration. Clear it so every clone
    # treats its first boot as first boot.
    #
    # This is the Windows equivalent of `cloud-init clean` on the Linux
    # templates, and it is the thing the link-clone test is really checking.
    #
    # STOP FIRST, THEN CLEAR. Clearing while the service is running leaves it
    # free to write the state straight back, and the clear would still report
    # success.
    Write-Host "Stopping cloudbase-init service before clearing its state"
    Stop-Service -Name 'cloudbase-init' -Force

    $stopped = $false
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        if ((Get-Service -Name 'cloudbase-init').Status -eq 'Stopped') {
            $stopped = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $stopped) {
        throw "cloudbase-init did not reach Stopped after Stop-Service (status: $((Get-Service -Name 'cloudbase-init').Status)). Refusing to clear instance state while the service can write it back."
    }
    Write-Host "Stopped cloudbase-init service"

    # No -ErrorAction SilentlyContinue in here: the previous version swallowed
    # every removal failure and then printed "Cleared ..." regardless, so a
    # re-arm that did nothing looked identical to one that worked.
    Write-Host "Re-arming Cloudbase-Init (clearing per-instance state)"
    $stateRemoved = Clear-CloudbaseInitState -Paths $StateKeyPaths
    Write-Host "Re-arm removed $stateRemoved state subkey(s)"

    # --- final assertions --------------------------------------------------
    # StartMode comes from CIM because that is the value the SCM will act on at
    # next boot; Status is re-read rather than reused from the object above.
    $cimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='cloudbase-init'"
    if (-not $cimSvc) {
        throw "cloudbase-init service disappeared from Win32_Service after configuration"
    }
    if ($cimSvc.StartMode -ne 'Auto') {
        throw "cloudbase-init StartMode is '$($cimSvc.StartMode)', expected 'Auto' - clones would never run cloud-init"
    }
    $finalSvc = Get-Service -Name 'cloudbase-init'
    if ($finalSvc.Status -ne 'Stopped') {
        throw "cloudbase-init is '$($finalSvc.Status)', expected 'Stopped' - it may re-populate instance state before the template is sealed"
    }

    # Re-read the state one last time, after everything else has settled. This
    # is the assertion the link-clone test really depends on, so it is made
    # against the live registry rather than inferred from the clear above.
    foreach ($stateKey in $StateKeyPaths) {
        if (-not (Test-Path -Path $stateKey)) { continue }
        $leftover = @(Get-ChildItem -Path $stateKey)
        if ($leftover.Count -ne 0) {
            throw "Cloudbase-Init instance state reappeared under $stateKey ($($leftover.PSChildName -join ', ')) - clones would skip cloud-init."
        }
    }

    Write-Host "Verified: cloudbase-init StartMode=$($cimSvc.StartMode), Status=$($finalSvc.Status)"
    Write-Host "Verified: no Cloudbase-Init instance state in either registry view"
    Write-Host "Cloudbase-Init re-armed (state cleared, service stopped but Automatic)"

    exit 0
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Opt-in debug hold: set PACKER_DEBUG_HOLD in the build environment to keep
    # the VM alive long enough to read the transcript before Packer destroys it.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set - sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
