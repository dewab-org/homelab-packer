###############################################################################
# Name:             60-install-cloudbase-init.ps1
# Description:      Install and configure Cloudbase-Init for Proxmox cloud-init
###############################################################################
#
# Cloudbase-Init is what makes a Windows template a *cloud* image: without it
# the cloud-init drive Proxmox attaches is inert and a clone ignores ciuser /
# cipassword / sshkeys / ipconfig entirely.
#
# Two things this script learned the hard way:
#
#   * The install must be VERIFIED, not assumed. The previous version ran
#     `Start-Process msiexec -Wait` and neither checked the exit code nor
#     confirmed the result, so a failed install exited 0 and the build shipped a
#     template with no Cloudbase-Init at all — the MSI sat downloaded in
#     C:\Install while 998-cleanup deleted the transcript that would have said
#     why. Anything that can fail quietly here will.
#
#   * Proxmox presents cloud-init data as a configdrive2 CD-ROM. The service
#     must therefore be pointed at ConfigDriveService with cdrom lookup enabled;
#     the stock config also enables HTTP/EC2 metadata services that do not exist
#     on this network and just add boot delay while they time out.

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/60-install-cloudbase-init.txt' -Append

try {
    $installerUrl = $env:CLOUDBASE_INIT_URL
    $checksum = $env:CLOUDBASE_INIT_CHECKSUM

    if ([string]::IsNullOrWhiteSpace($installerUrl)) {
        # Not a silent skip: a template without Cloudbase-Init is not a cloud
        # image, so fail rather than quietly producing a broken artifact.
        throw "CLOUDBASE_INIT_URL is not set. Set cloudbase_init_url in the build's variables.auto.pkrvars.hcl."
    }

    $installerPath = 'C:\Install\cloudbase-init.msi'
    Write-Host "Downloading Cloudbase-Init from $installerUrl"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace($checksum) -and $checksum -ne 'none') {
        $parts = $checksum.Split(':', 2)
        if ($parts.Count -eq 2) {
            $algo = $parts[0].ToUpper()
            $expected = $parts[1].ToLower()
            $actual = (Get-FileHash -Path $installerPath -Algorithm $algo).Hash.ToLower()
            if ($actual -ne $expected) {
                throw "Cloudbase-Init checksum mismatch: expected $expected, got $actual"
            }
            Write-Host "Checksum OK ($algo)"
        }
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

    # Verify rather than trust the exit code — msiexec has been observed to
    # return before the product is actually registered.
    $installDir = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
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
username=Admin
groups=Administrators
inject_user_password=true
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
; Do not force a password change at first logon. Without this Cloudbase-Init
; creates the user with "must change password", so the cloud-init password is
; correct but immediately rejected — remote login and WinRM both fail on a
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
    foreach ($f in @('cloudbase-init.conf', 'cloudbase-init-unattend.conf')) {
        Set-Content -Path (Join-Path $confDir $f) -Value $conf -Encoding ASCII
        Write-Host "Wrote $f"
    }

    # The service must start on boot for a clone to be configured at all.
    Set-Service -Name 'cloudbase-init' -StartupType Automatic
    Write-Host "cloudbase-init service set to Automatic"

    # --- re-arm ------------------------------------------------------------
    # Cloudbase-Init records which plugins it has already executed, keyed by
    # instance id, under HKLM\SOFTWARE\Cloudbase Solutions\Cloudbase-Init. The
    # service is Automatic from here, so it can well run once more on this build
    # VM before packer seals it — and a template carrying "already done" state
    # produces clones that silently skip configuration. Clear it so every clone
    # treats its first boot as first boot.
    #
    # This is the Windows equivalent of `cloud-init clean` on the Linux
    # templates, and it is the thing the link-clone test is really checking.
    $stateKey = 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init'
    if (Test-Path $stateKey) {
        Get-ChildItem -Path $stateKey -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared Cloudbase-Init state: $($_.PSChildName)"
        }
    }
    # Stop the service so it cannot re-populate that state before shutdown.
    Stop-Service -Name 'cloudbase-init' -Force -ErrorAction SilentlyContinue
    Write-Host "Cloudbase-Init re-armed (state cleared, service stopped but Automatic)"
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
