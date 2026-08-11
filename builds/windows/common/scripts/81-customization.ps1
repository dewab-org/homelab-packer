###############################################################################
# Name:             81-customization.ps1
# Description:      Post-install Windows customization: strip the media folders
#                   from This PC, write Explorer/taskbar/accessibility defaults
#                   into the DEFAULT USER hive, force High Performance power,
#                   disable hibernation and sleep, silence Server Manager.
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################
#
# WHAT IT DOES
#   1. Starts the transcript at C:/Install/81-customization.txt.
#   2. Removes the Documents / Music / Pictures / Videos / 3D Objects namespace
#      keys from This PC, in both the native and Wow6432Node HKLM views.
#   3. Reads the Windows edition to decide whether this is Server Core.
#   4. Builds ONE data list of per-user settings: the Ease of Access Flags
#      (StickyKeys / Keyboard Response / ToggleKeys, REG_SZ not DWORD) unless
#      this is Core, plus Explorer view defaults (Hidden, HideFileExt,
#      HideDrivesWithNoMedia, ShowSyncProviderNotifications, LaunchTo=This PC)
#      and taskbar defaults (EnableAutoTray off, small icons, combine only when
#      the taskbar is full).
#   5. Mounts C:\Users\Default\NTUSER.DAT as HKLM\PACKER_DEFAULT, writes every
#      setting, then unloads the hive.
#   6. RE-MOUNTS the hive and re-asserts every one of those settings.
#   7. Activates the High Performance power scheme by GUID and re-reads the
#      active scheme.
#   8. Runs `powercfg /hibernate off` and checks the outcome two ways.
#   9. Sets HKLM ServerManager\DoNotOpenServerManagerAtLogon = 1.
#  10. Zeroes the eight monitor/disk/standby/hibernate AC+DC timeouts.
#
# WHAT IT VERIFIES
#   - Every namespace key removal: the path must not exist afterwards.
#   - Every registry write is read back and compared to the intended value.
#   - THE DEFAULT-USER WRITES ARE VERIFIED TWICE: once inside the mounted hive,
#     then AGAIN after the hive is unloaded and re-mounted. A read from a
#     still-open hive only proves the write reached memory; what a clone user
#     inherits is what survived the flush to NTUSER.DAT. The same declared list
#     drives both passes, so it is impossible to verify something other than
#     what was written.
#   - The hive unload itself: five attempts with GC in between, and a failure
#     is fatal - leaving the hive mounted corrupts the profile template every
#     cloned VM's first user is created from.
#   - The active power scheme is re-read with `powercfg /getactivescheme` and
#     matched against the GUID.
#   - Hibernation is judged by C:\hiberfil.sys actually being gone (the
#     disk-space outcome, several GB of template) AND by HibernateEnabled in
#     the registry (the configured state) - never by powercfg's exit code.
#   - Each `powercfg /change` exit code.
#
# FAILURE CONTRACT
#   FATAL     : a namespace key that still exists after removal; any registry
#               value that does not read back; the default hive being missing,
#               already mounted, failing to load, failing to unload, or failing
#               the post-remount assertion; powercfg /setactive returning
#               non-zero or the active scheme not matching; hiberfil.sys still
#               present after three checks; HibernateEnabled set to anything
#               but 0; any powercfg /change failing. All exit 1.
#   LOUD SKIP : the Ease of Access block on Server Core, which has no
#               accessibility UI. It prints a line saying exactly that and that
#               nothing else is skipped. Two softer notices: a namespace key
#               that was already absent prints "Skipping missing path", and if
#               HibernateEnabled does not exist at all (firmware without
#               hibernation support) a NOTE says so and the absence of
#               hiberfil.sys is treated as the operative proof. A non-zero
#               `powercfg /hibernate off` with the file gone warns and
#               continues.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   Optional. On failure, sleep 3600s before exiting so the
#                       VM can be inspected before Packer destroys it.
#
# NOTES
#   - PER-USER SETTINGS GO INTO THE DEFAULT USER HIVE, NOT HKCU. HKCU during a
#     Packer run is the disposable build account: anything written there is
#     thrown away with that profile and no clone user ever sees it. Everything
#     per-user therefore goes into C:\Users\Default\NTUSER.DAT via `reg load`,
#     which is the template new profiles are copied from. Machine-wide state
#     (power, hibernation, Server Manager, the This-PC namespace keys) stays in
#     HKLM.
#   - The High Performance GUID is hardcoded on purpose. Looking the plan up by
#     ElementName could return $null, and the old code then ran
#     `powercfg /setactive ""` - which fails invisibly, because powercfg does
#     not throw on a non-zero exit.
#   - Remove-Item needs -Recurse here: without it, deleting a registry key that
#     has subkeys stops to confirm, which in a non-interactive provisioner is
#     an error rather than a deletion.
#   - The registry provider holds handles open, so the unload path forces a GC
#     and retries; without that `reg unload` fails with "Access is denied".
#   - Disabling hibernation by registry value alone neither turns it off nor
#     reclaims hiberfil.sys - that was the old behaviour.
#   - Disabling Administrator password expiration is deliberately left
#     commented out at the end of the script.

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/81-customization.txt' -Append

# Well-known GUID of the High Performance power scheme. Looking the plan up by
# ElementName could return $null, and the old code then ran `powercfg /setactive
# ""`, which fails invisibly because powercfg does not throw on non-zero exit.
$HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# The media folders to strip from This PC, as data rather than eighteen
# near-identical call lines. Each folder has one or two CLSIDs, and each CLSID
# has to be removed from BOTH the native and the Wow6432Node view of the
# MyComputer\NameSpace key - a 32-bit Explorer host reads the Wow6432Node copy,
# so removing only the native one leaves the folder visible there.
$thisPcNamespaceViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace'
)
$thisPcNamespaceFolders = @(
    @{ Name = 'Documents'; Clsids = @('{A8CDFF1C-4878-43be-B5FD-F8091C1C60D0}', '{d3162b92-9365-467a-956b-92703aca08af}') }
    @{ Name = 'Music'; Clsids = @('{1CF1260C-4DD0-4ebb-811F-33C572699FDE}', '{3dfdf296-dbec-4fb4-81d1-6a3438bcf4de}') }
    @{ Name = 'Pictures'; Clsids = @('{3ADD1653-EB32-4cb0-BBD7-DFA0ABB5ACCA}', '{24ad3ad4-a569-4530-98e1-ab02f9417aa8}') }
    @{ Name = 'Videos'; Clsids = @('{A0953C92-50DC-43bf-BE83-3742FED03C9C}', '{f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a}') }
    @{ Name = '3D Objects'; Clsids = @('{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}') }
)

function Remove-RegistryPathWhenPresent {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -Path $Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Remove registry key')) {
            # -Recurse matters: Remove-Item on a registry key that has subkeys
            # stops to confirm without it, which in a non-interactive
            # provisioner is an error rather than a deletion.
            Remove-Item -Path $Path -Recurse -Force
            if (Test-Path -Path $Path) {
                throw "Removed $Path but it still exists"
            }
            Write-Host "Removed: $Path"
        }
    }
    else {
        Write-Host "Skipping missing path: $Path"
    }
}

function Write-VerifiedRegistryValue {
    # Create the key if needed, set the value, then read it back and compare.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'String')][string]$Type = 'DWord'
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null

    $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ("$actual" -ne "$Value") {
        throw "Registry verification failed for $Path\$Name - expected '$Value', found '$actual'"
    }
    Write-Host "Set and verified $Path\$Name = $actual"
}

function Confirm-RegistryValue {
    # Read-only assertion, used to re-check the default user hive after it has
    # been unloaded and re-mounted.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Post-unload verification failed: key $Path does not exist"
    }
    $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ("$actual" -ne "$Value") {
        throw "Post-unload verification failed for $Path\$Name - expected '$Value', found '$actual'. The write did not survive the flush to NTUSER.DAT, so no clone user would get it."
    }
}

function Invoke-OnDefaultUserHive {
    # Mount C:\Users\Default\NTUSER.DAT, run $Action with the mounted hive's
    # PS path, then unload it. The unload is mandatory: leaving the hive
    # mounted at the end of a build corrupts the default profile that every
    # cloned VM's first user is created from, so a failed unload is fatal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $hiveName = 'PACKER_DEFAULT'
    $hiveKey = "HKLM\$hiveName"
    $hivePsPath = "HKLM:\$hiveName"
    $ntuserDat = 'C:\Users\Default\NTUSER.DAT'

    if (-not (Test-Path -Path $ntuserDat)) {
        throw "Default user hive not found at $ntuserDat"
    }
    if (Test-Path -Path $hivePsPath) {
        throw "$hiveKey is already mounted - a previous run left the default user hive loaded. Unload it before continuing."
    }

    & reg.exe load $hiveKey $ntuserDat | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg load $hiveKey $ntuserDat failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -Path $hivePsPath)) {
        throw "reg load reported success but $hivePsPath is not present"
    }
    Write-Host "Mounted default user hive at $hivePsPath"

    try {
        & $Action $hivePsPath
    }
    finally {
        # The registry provider keeps handles open; drop them before unloading
        # or `reg unload` fails with "Access is denied".
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $unloaded = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & reg.exe unload $hiveKey | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $unloaded = $true
                break
            }
            Write-Host "reg unload attempt $attempt failed (exit $LASTEXITCODE); retrying"
            Start-Sleep -Seconds 2
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
        if (-not $unloaded -or (Test-Path -Path $hivePsPath)) {
            throw "Failed to unload $hiveKey. The default user profile must not be left mounted."
        }
        Write-Host "Unloaded default user hive"
    }
}

try {
    # Remove the media folders from This PC, native view then Wow6432Node view.
    foreach ($folder in $thisPcNamespaceFolders) {
        Write-Host "Remove $($folder.Name) Folder"
        foreach ($view in $thisPcNamespaceViews) {
            foreach ($clsid in $folder.Clsids) {
                Remove-RegistryPathWhenPresent -Path "$view\$clsid"
            }
        }
    }

    # --- per-user defaults (default profile, NOT the build account) ---------
    $edition = (Get-WindowsEdition -Online).Edition
    $isCoreEdition = ($edition -match "cor")
    Write-Host "Windows edition is $edition (core: $isCoreEdition)"

    # Declared as data so the exact same list can be written into the hive and
    # then re-asserted against it after the hive has been unloaded and
    # re-mounted. Keeping one list removes the "verified something other than
    # what was written" failure mode.
    $advancedRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorerRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'

    $defaultUserSettings = @()

    # Disable Ease of Access keyboard shortcuts. These Flags values are REG_SZ,
    # not DWORD. Server Core has no accessibility UI to trip over.
    if ($isCoreEdition) {
        Write-Host "Server Core edition detected - SKIPPING the Ease of Access keyboard shortcut settings (no accessibility UI on Core). Nothing else is skipped."
    }
    else {
        $defaultUserSettings += @(
            @{ Path = 'Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Value = '506'; Type = 'String' }
            @{ Path = 'Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Value = '122'; Type = 'String' }
            @{ Path = 'Control Panel\Accessibility\ToggleKeys'; Name = 'Flags'; Value = '58'; Type = 'String' }
        )
    }

    $defaultUserSettings += @(
        # Sensible Explorer view defaults; LaunchTo=1 opens Explorer on This PC.
        @{ Path = $advancedRel; Name = 'Hidden'; Value = 1; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'HideFileExt'; Value = 0; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'HideDrivesWithNoMedia'; Value = 0; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'ShowSyncProviderNotifications'; Value = 0; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'LaunchTo'; Value = 1; Type = 'DWord' }
        # Sensible taskbar defaults: show all notification area icons, small
        # taskbar buttons, combine only when the taskbar is full.
        @{ Path = $explorerRel; Name = 'EnableAutoTray'; Value = 0; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'TaskbarSmallIcons'; Value = 1; Type = 'DWord' }
        @{ Path = $advancedRel; Name = 'TaskbarGlomLevel'; Value = 1; Type = 'DWord' }
    )

    Write-Host "Writing $($defaultUserSettings.Count) per-user default(s) into the default profile hive"
    Invoke-OnDefaultUserHive -Action {
        param($HiveRoot)

        foreach ($setting in $defaultUserSettings) {
            Write-VerifiedRegistryValue -Path "$HiveRoot\$($setting.Path)" `
                -Name $setting.Name -Value $setting.Value -Type $setting.Type
        }
    }

    # Second pass, against a freshly mounted hive: proves the values were
    # flushed to C:\Users\Default\NTUSER.DAT and not merely written to a hive
    # that was about to be discarded.
    Write-Host "Re-mounting the default profile hive to confirm the writes survived"
    Invoke-OnDefaultUserHive -Action {
        param($HiveRoot)

        foreach ($setting in $defaultUserSettings) {
            Confirm-RegistryValue -Path "$HiveRoot\$($setting.Path)" `
                -Name $setting.Name -Value $setting.Value
        }
        Write-Host "Confirmed $($defaultUserSettings.Count) per-user default(s) after unload/remount"
    }

    # --- power plan ---------------------------------------------------------
    Write-Host "Setting power plan to high performance..."
    & powercfg.exe /setactive $HighPerformanceGuid
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setactive $HighPerformanceGuid failed with exit code $LASTEXITCODE (is the High Performance scheme present on this edition?)"
    }
    $activeScheme = (& powercfg.exe /getactivescheme) -join ' '
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /getactivescheme failed with exit code $LASTEXITCODE"
    }
    if ($activeScheme -notmatch [regex]::Escape($HighPerformanceGuid)) {
        throw "Power plan verification failed - active scheme is '$activeScheme', expected GUID $HighPerformanceGuid"
    }
    Write-Host "Verified active power scheme: $activeScheme"

    # --- hibernation --------------------------------------------------------
    # Registry alone neither disables hibernation nor reclaims hiberfil.sys
    # (several GB of template image). powercfg does both; the file's absence is
    # the real proof, so that is what is asserted - powercfg's exit code is only
    # reported, because on hardware/firmware without hibernation support it can
    # return non-zero while the desired end state already holds.
    Write-Host "Disable hibernation"
    & powercfg.exe /hibernate off
    $hibExit = $LASTEXITCODE
    Write-Host "powercfg /hibernate off exit code: $hibExit"

    $hiberfil = 'C:\hiberfil.sys'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Test-Path -Path $hiberfil)) { break }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -Path $hiberfil) {
        throw "Hibernation is still enabled: $hiberfil still exists after 'powercfg /hibernate off' (exit code $hibExit)"
    }
    if ($hibExit -ne 0) {
        Write-Host "WARNING: powercfg /hibernate off returned $hibExit, but $hiberfil is absent - treating hibernation as disabled."
    }
    Write-Host "Verified: $hiberfil is absent"

    # Second, independent check. The file being absent is the disk-space
    # outcome; HibernateEnabled is the configured state powercfg claims to have
    # changed, and the two can disagree (fast startup can recreate the file on a
    # later boot). Read it back from the live system rather than assuming.
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hibernateEnabled = (Get-ItemProperty -Path $powerKey -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
    if ($null -eq $hibernateEnabled) {
        Write-Host "NOTE: $powerKey\HibernateEnabled is not present. On hardware/firmware without hibernation support powercfg does not create it; $hiberfil being absent is the operative proof."
    }
    elseif ([int]$hibernateEnabled -ne 0) {
        throw "Hibernation is still configured on: $powerKey\HibernateEnabled = $hibernateEnabled (exit code $hibExit). $hiberfil is absent now but a later boot can recreate it inside the template."
    }
    else {
        Write-Host "Verified: $powerKey\HibernateEnabled = 0"
    }

    # --- machine-wide odds and ends -----------------------------------------
    # Disable server manager from starting on login
    Write-Host "Disable server manager from starting on login"
    Write-VerifiedRegistryValue -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1

    # Disable sleep
    Write-Host "Disable sleep"
    $timeouts = @(
        'monitor-timeout-ac', 'monitor-timeout-dc',
        'disk-timeout-ac', 'disk-timeout-dc',
        'standby-timeout-ac', 'standby-timeout-dc',
        'hibernate-timeout-ac', 'hibernate-timeout-dc'
    )
    foreach ($timeout in $timeouts) {
        & powercfg.exe /change $timeout 0
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg /change $timeout 0 failed with exit code $LASTEXITCODE"
        }
        Write-Host "powercfg /change $timeout 0 OK"
    }

    # Disable password expiration for Administrator
    # Write-Host "Disable Administrator password expiration"
    # Set-LocalUser -Name "Administrator" -PasswordNeverExpires $true

    exit 0
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Opt-in debug hold: set PACKER_DEBUG_HOLD in the build environment to keep
    # the VM alive long enough to read this transcript before Packer destroys it.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set - sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
