###############################################################################
# Name:             30-set-temp.ps1
# Description:      Creates C:\TEMP and points TEMP and TMP at it in four
#                   scopes - Machine, the Packer build account's User scope,
#                   the current Process, and the Default User profile hive
#                   (C:\Users\Default\NTUSER.DAT) - reading each write back
#                   from the live system before reporting success.
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and opens a transcript at
#      C:\Install\30-set-temp.txt.
#   2. Creates the C:\TEMP directory.
#   3. Writes TEMP and TMP = C:\TEMP in each of four scopes, in this order:
#
#        MACHINE  - system-wide, persisted. Applies to services and to the
#                   system context on every clone of this template.
#        USER     - the disposable Packer build account only. This account
#                   is removed/expired before the template is sealed, so
#                   this write survives nothing; it exists purely to keep
#                   the rest of the build consistent with Machine scope.
#        PROCESS  - the running provisioner, so the remainder of THIS script
#                   run and this PowerShell session use C:\TEMP too. Dies
#                   with the process.
#        DEFAULT  - HKU-equivalent write into the Default User profile hive.
#          USER     THIS is the one interactive users on clones actually
#          HIVE     inherit: Windows copies C:\Users\Default when it creates
#                   a new profile, so every user account created on a clone
#                   is born with TEMP/TMP = C:\TEMP. Without this write,
#                   new users would silently fall back to the per-profile
#                   %USERPROFILE%\AppData\Local\Temp default.
#
#   4. For the hive write: reg.exe load HKLM\PACKER_DEFAULT from
#      C:\Users\Default\NTUSER.DAT, reg add both values under
#      ...\Environment as REG_EXPAND_SZ, read them back, then reg unload.
#
# WHAT IT VERIFIES
#   - C:\TEMP exists as a directory after New-Item.
#   - Machine, User and Process TEMP/TMP each read back as exactly C:\TEMP
#     via [Environment]::GetEnvironmentVariable for that target.
#   - C:\Users\Default\NTUSER.DAT exists before any attempt to seed it;
#     its absence means future users cannot be seeded and is fatal rather
#     than skipped.
#   - Every reg.exe invocation is checked for exit code 0 (load, add, query
#     and unload) - reg.exe does not throw.
#   - TEMP and TMP are queried back out of the MOUNTED hive and parsed as
#     REG_EXPAND_SZ values equal to C:\TEMP. A successful 'reg add' is not
#     taken as proof.
#   - The hive is genuinely unmounted afterwards: reg unload must return 0
#     within 5 attempts AND HKLM:\PACKER_DEFAULT must no longer be present.
#     A hive left mounted locks the Default profile for everything after it.
#
# FAILURE CONTRACT
#   FATAL     : C:\TEMP missing after creation; any scope reading back a
#               value other than C:\TEMP; the Default user hive file
#               missing; reg load/add/query failing; the stale-mount
#               cleanup failing; reg unload failing 5 times; or
#               HKLM:\PACKER_DEFAULT still present after unload reported
#               success. All exit 1 and fail the provisioner.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
# NOTES
#   - A previous failed run can leave HKLM\PACKER_DEFAULT mounted, which
#     makes the next 'reg load' fail. The script therefore checks for and
#     unloads a stale mount first.
#   - The hive writes deliberately run WITHOUT a finally block. The error
#     from a failed write is captured in $hiveError and rethrown only after
#     the unload loop has run, so that a write failure and an unload failure
#     are both reported instead of one masking the other.
#   - The unload loop calls [gc]::Collect() and WaitForPendingFinalizers()
#     between attempts: a lingering .NET registry handle is the usual reason
#     reg unload fails, and forcing finalization is what releases it.
#   - The explicit 'exit 0' is load-bearing. Packer's default powershell
#     execute_command ends with 'exit $LastExitCode', which would otherwise
#     propagate whatever the last native command (reg.exe) left behind.
#   - Wired into every Windows build: the 2022 and 2025 Core and Desktop
#     Experience ISO builds, and common/cloud-clone-build.pkr.hcl.
###############################################################################

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# Start-Transcript throws if the directory is missing. Do not rely on an
# earlier provisioner having created C:\Install.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null

Start-Transcript -Path 'C:/Install/30-set-temp.txt' -Append

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

try {
    Write-Host "Configuring temp folder"
    $TempFolder = 'C:\TEMP'
    $varNames = @('TEMP', 'TMP')

    New-Item -ItemType Directory -Force -Path $TempFolder | Out-Null

    # Verify the effect: the directory must exist.
    if (-not (Test-Path -LiteralPath $TempFolder -PathType Container)) {
        throw "Temp directory '$TempFolder' does not exist after New-Item."
    }
    Write-Host "Verified directory '$TempFolder' exists"

    # ---------------------------------------------------------------------
    # The three [Environment] scopes, declared as data so the write and the
    # read-back cannot drift apart:
    #
    #   Machine - persisted for the whole system; what services and the
    #             system context on every clone use.
    #   User    - the disposable Packer build account only. It is
    #             removed/expired before the template is sealed, so this
    #             write survives nothing; it exists to keep the rest of the
    #             build consistent with the machine scope.
    #   Process - the running provisioner, so the remainder of THIS script
    #             run uses C:\TEMP too. Dies with the process.
    #
    # Each scope writes BOTH variables first and only then reads BOTH back,
    # so the assertion is made against the finished state of that scope.
    # ---------------------------------------------------------------------
    $scopes = @(
        @{ Target = [EnvironmentVariableTarget]::Machine; Label = 'Machine-scope' }
        @{ Target = [EnvironmentVariableTarget]::User; Label = 'Build-account user-scope' }
        @{ Target = [EnvironmentVariableTarget]::Process; Label = 'Process-scope' }
    )

    foreach ($scope in $scopes) {
        foreach ($varName in $varNames) {
            [Environment]::SetEnvironmentVariable($varName, $TempFolder, $scope.Target)
        }
        foreach ($varName in $varNames) {
            $live = [Environment]::GetEnvironmentVariable($varName, $scope.Target)
            if ($live -ne $TempFolder) {
                throw "$($scope.Label) $varName is '$live' after being set, expected '$TempFolder'."
            }
            Write-Host "Verified $($scope.Label) $varName = $live"
        }
    }

    # ---------------------------------------------------------------------
    # Default User profile hive, so users created on clones inherit C:\TEMP.
    # ---------------------------------------------------------------------
    $defaultHiveFile = 'C:\Users\Default\NTUSER.DAT'
    $mountPoint = 'HKLM\PACKER_DEFAULT'
    $mountPointPs = 'HKLM:\PACKER_DEFAULT'

    if (-not (Test-Path -LiteralPath $defaultHiveFile)) {
        throw "Default user hive '$defaultHiveFile' not found - cannot seed TEMP/TMP for future users."
    }

    # A previous failed run may have left the hive mounted.
    if (Test-Path -LiteralPath $mountPointPs) {
        Write-Host "Unloading stale hive mount $mountPoint"
        & reg.exe unload $mountPoint | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "reg unload $mountPoint failed with exit code $LASTEXITCODE while clearing a stale mount."
        }
    }

    Write-Host "Loading $defaultHiveFile as $mountPoint"
    & reg.exe load $mountPoint $defaultHiveFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg load $mountPoint $defaultHiveFile failed with exit code $LASTEXITCODE."
    }

    # Do the writes without a finally block so that a write failure and an
    # unload failure are both reported instead of one masking the other.
    $hiveError = $null
    try {
        foreach ($varName in $varNames) {
            & reg.exe add "$mountPoint\Environment" /v $varName /t REG_EXPAND_SZ /d $TempFolder /f | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg add $mountPoint\Environment /v $varName failed with exit code $LASTEXITCODE."
            }
        }

        # Verify the effect: read the values back out of the mounted hive.
        foreach ($varName in $varNames) {
            $queryOutput = & reg.exe query "$mountPoint\Environment" /v $varName
            if ($LASTEXITCODE -ne 0) {
                throw "reg query $mountPoint\Environment /v $varName failed with exit code $LASTEXITCODE."
            }
            $pattern = '^\s*' + [regex]::Escape($varName) + '\s+REG_EXPAND_SZ\s+(?<value>.+?)\s*$'
            $match = $queryOutput | Select-String -Pattern $pattern | Select-Object -First 1
            if (-not $match) {
                throw ("Could not read $varName back from the default user hive:`n" + ($queryOutput -join "`n"))
            }
            $liveValue = $match.Matches[0].Groups['value'].Value
            if ($liveValue -ne $TempFolder) {
                throw "Default-user-hive $varName is '$liveValue', expected '$TempFolder'."
            }
            Write-Host "Verified default-user-hive $varName = $liveValue"
        }
    }
    catch {
        $hiveError = $PSItem
    }

    # Always unload - a hive left mounted locks the Default profile.
    $unloaded = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload $mountPoint | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $unloaded = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if ($hiveError) { throw $hiveError }
    if (-not $unloaded) {
        throw "reg unload $mountPoint failed after 5 attempts - the default user hive is still mounted."
    }
    if (Test-Path -LiteralPath $mountPointPs) {
        throw "$mountPoint is still present after reg unload reported success."
    }
    Write-Host "Verified default user hive unloaded"

    Write-Host "Temp folder configuration complete: $TempFolder"

    # Explicit success code. Packer's default powershell execute_command ends
    # with 'exit $LastExitCode', which would otherwise propagate whatever the
    # last native command (reg.exe) left behind.
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
