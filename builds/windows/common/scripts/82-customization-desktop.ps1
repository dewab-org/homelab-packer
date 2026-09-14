###############################################################################
# Name:             82-customization-desktop.ps1
# Description:      Desktop-edition customization: write taskbar/Cortana
#                   defaults into the DEFAULT USER hive, and remove the bundled
#                   Store apps both as installed packages (all users) and as
#                   provisioned packages on the image.
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################
#
# WHAT IT DOES
#   1. Starts the transcript at C:/Install/82-customization-desktop.txt.
#   2. Mounts C:\Users\Default\NTUSER.DAT as HKLM\PACKER_DEFAULT and writes
#      three per-user defaults - SearchboxTaskbarMode=0 and ShowCortanaButton=0
#      (no Cortana/search box on the taskbar) and EnableAutoTray=0 (stop
#      autohiding the notification area) - then unloads the hive.
#   3. RE-MOUNTS the hive and re-asserts all three.
#   4. Counts the ENTIRE Appx inventory - installed (all users) and provisioned
#      - before removing anything.
#   5. For each of the ~19 wildcard patterns in $xpackages: removes the
#      installed package for ALL USERS, removes the PROVISIONED package from
#      the image, then re-queries both.
#   6. Reports every failure by name and decides the exit code.
#
# WHAT IT VERIFIES
#   - THE DEFAULT-USER WRITES ARE VERIFIED TWICE: once inside the mounted hive
#     and again after unloading and re-mounting it. A read from a still-open
#     hive only proves the write reached memory; what a clone user inherits is
#     what survived the flush to C:\Users\Default\NTUSER.DAT. One declared list
#     drives both passes.
#   - The hive unload (five attempts with GC in between); a failure is fatal,
#     because a hive left mounted corrupts the profile template every clone
#     user is created from.
#   - Each package is re-queried after removal - installed AND provisioned -
#     which is the only proof it is actually gone and will not come back for
#     the next new user.
#   - THE INVENTORY SANITY GATE. A broken Appx/DISM stack (or Server Core
#     without the Appx cmdlets) returns nothing for every query, which would
#     make every per-package "verified removed" check pass without a thing
#     being done. If the up-front count is zero installed AND zero provisioned,
#     a banner states that the lines below are NOT evidence of anything, and
#     the final summary refuses to call the result verified-clean.
#
# FAILURE CONTRACT
#   FATAL     : the default hive missing, already mounted, failing to load,
#               failing to unload, or failing the post-remount assertion; and
#               any package that could not be removed or is still present after
#               removal. Exits 1 - the build must not claim a clean desktop
#               image it did not produce.
#   LOUD SKIP : APPX_REMOVAL_OPTIONAL=1 downgrades the package-removal failures
#               to a printed list and continues to exit 0. Some inbox apps
#               genuinely become non-removable in later Windows builds - that
#               is a real change worth noticing before silencing it, so the
#               failures are still enumerated. The empty-inventory case also
#               exits 0, but explicitly says the result is NOT verified clean.
#
# INPUTS (environment)
#   APPX_REMOVAL_OPTIONAL   Set to '1' to downgrade package-removal failures to
#                           warnings. Unset = failures are fatal.
#   PACKER_DEBUG_HOLD       Optional. On failure, sleep 3600s before exiting so
#                           the VM can be inspected.
#
# NOTES
#   - Two scoping bugs used to make this script largely decorative. The
#     taskbar/Cortana tweaks were written to HKCU, which during a Packer run is
#     the disposable build account, so no clone user ever saw them. And app
#     removal used Get-AppxPackage/Remove-AppxPackage WITHOUT -AllUsers and
#     never touched the PROVISIONED packages, so everything removed came
#     straight back for each newly created user.
#   - The nested -ErrorAction SilentlyContinue that hid every removal failure
#     is gone; failures are collected and reported per package.
#   - '*people*' is deliberately commented out of $xpackages.

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$xpackages = @(
    '*3dbuilder*',
    '*windowsalarms*',
    '*windowscommunicationsapps*',
    '*windowscamera*',
    '*skypeapp*',
    '*getstarted*',
    '*zunemusic*',
    '*windowsmaps*',
    '*solitairecollection*',
    '*bingfinance*',
    '*zunevideo*',
    '*bingnews*',
    '*onenote*',
    #'*people*',
    '*windowsphone*',
    '*photos*',
    '*bingsports*',
    '*soundrecorder*',
    '*bingweather*',
    '*xboxapp*'
)

Start-Transcript -Path 'C:/Install/82-customization-desktop.txt' -Append

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
    # PS path, then unload it. A failed unload is fatal: leaving the hive
    # mounted corrupts the profile template every clone user is created from.
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
    # Declared as data so the identical list can be written into the hive and
    # then re-asserted after unload/remount.
    $defaultUserSettings = @(
        # Remove Cortana / the search box from the taskbar.
        @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
        @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCortanaButton'; Value = 0 }
        # Stop autohiding the notification area.
        @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'EnableAutoTray'; Value = 0 }
    )

    Write-Host "Writing $($defaultUserSettings.Count) per-user default(s) into the default profile hive"
    Invoke-OnDefaultUserHive -Action {
        param($HiveRoot)

        foreach ($setting in $defaultUserSettings) {
            Write-VerifiedRegistryValue -Path "$HiveRoot\$($setting.Path)" -Name $setting.Name -Value $setting.Value
        }
    }

    # Second pass against a freshly mounted hive. Reading a value back out of a
    # hive that is still open only proves the write reached memory; what clones
    # inherit is what survived the flush to C:\Users\Default\NTUSER.DAT.
    Write-Host "Re-mounting the default profile hive to confirm the writes survived"
    Invoke-OnDefaultUserHive -Action {
        param($HiveRoot)

        foreach ($setting in $defaultUserSettings) {
            Confirm-RegistryValue -Path "$HiveRoot\$($setting.Path)" -Name $setting.Name -Value $setting.Value
        }
        Write-Host "Confirmed $($defaultUserSettings.Count) per-user default(s) after unload/remount"
    }

    # --- remove obnoxious packages ------------------------------------------
    $failures = New-Object System.Collections.Generic.List[string]

    # Sanity gate before any "verified removed" claim is made. If the Appx
    # subsystem returns nothing for everything - broken WinRT stack, Server Core
    # without the Appx cmdlets, DISM in a bad state - then every per-package
    # re-query below trivially "passes" and the script would report a clean
    # image it never touched. Count the whole surface once, up front.
    $allProvisioned = @(Get-AppxProvisionedPackage -Online)
    $allInstalled = @(Get-AppxPackage -AllUsers)
    Write-Host "Appx inventory before removal: $($allInstalled.Count) installed (all users), $($allProvisioned.Count) provisioned."
    if ($allInstalled.Count -eq 0 -and $allProvisioned.Count -eq 0) {
        Write-Host "*******************************************************************"
        Write-Host "WARNING: the Appx subsystem reports ZERO installed and ZERO"
        Write-Host "WARNING: provisioned packages. That is not a normal desktop image."
        Write-Host "WARNING: the per-package 'verified removed' lines below are therefore"
        Write-Host "WARNING: NOT evidence of anything - they only mean the queries came"
        Write-Host "WARNING: back empty. Investigate the Appx/DISM stack on this image."
        Write-Host "*******************************************************************"
        $warnedEmptyAppxInventory = $true
    }
    else {
        $warnedEmptyAppxInventory = $false
    }

    foreach ($package in $xpackages) {
        Write-Host "Removing package $package."

        # Installed packages, for every user - not just the build account.
        foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $package)) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
                Write-Host "  removed installed package $($pkg.PackageFullName)"
            }
            catch {
                $failures.Add("$($pkg.PackageFullName): $($_.Exception.Message)")
                Write-Host "  FAILED to remove installed package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }

        # Provisioned packages: without this, the app is reinstalled for every
        # newly created user and the removal above is pointless.
        foreach ($prov in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $package })) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName | Out-Null
                Write-Host "  removed provisioned package $($prov.PackageName)"
            }
            catch {
                $failures.Add("$($prov.PackageName): $($_.Exception.Message)")
                Write-Host "  FAILED to remove provisioned package $($prov.PackageName): $($_.Exception.Message)"
            }
        }

        # Re-query: the only proof the package is actually gone.
        $stillInstalled = @(Get-AppxPackage -AllUsers -Name $package)
        $stillProvisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $package })
        if ($stillInstalled.Count -eq 0 -and $stillProvisioned.Count -eq 0) {
            Write-Host "  verified: $package is not installed and not provisioned"
        }
        else {
            $detail = "$package still present (installed: $($stillInstalled.Count), provisioned: $($stillProvisioned.Count))"
            $failures.Add($detail)
            Write-Host "  NOT REMOVED: $detail"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host
        Write-Host "The following packages could not be removed:"
        foreach ($failure in $failures) {
            Write-Host "  - $failure"
        }
        if ($env:APPX_REMOVAL_OPTIONAL -eq '1') {
            Write-Host "APPX_REMOVAL_OPTIONAL=1 - continuing despite the failures above."
        }
        else {
            throw "$($failures.Count) package removal(s) failed. Set APPX_REMOVAL_OPTIONAL=1 if these apps are genuinely non-removable on this Windows build."
        }
    }
    elseif ($warnedEmptyAppxInventory) {
        Write-Host "No targeted package was found installed or provisioned - but see the empty-inventory warning above; this is NOT a verified-clean result."
    }
    else {
        Write-Host "All targeted packages verified removed (installed and provisioned)."
    }

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
