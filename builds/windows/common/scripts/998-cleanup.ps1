###############################################################################
# Name:             998-cleanup.ps1
# Description:      Reclaim disk before the VM is turned into a template: temp
#                   files, event logs, the Windows Update cache, prefetch, the
#                   recycle bin and downloaded installers. Splits essential
#                   work from best-effort and fails only on the essential.
# Author:           Daniel Whicker
# Date:             2024-05-29
###############################################################################
#
# WHAT IT DOES
#   1. Resolves -RemoveTranscripts (switch or environment variable), creates
#      C:\Install, starts the transcript, records free space on C:.
#   2. BEST EFFORT: purges C:\Windows\Temp and $env:TEMP, excluding packer-*
#      and protecting the currently running script.
#   3. ESSENTIAL: enumerates every event log channel with `wevtutil el` and
#      clears each one.
#   4. BEST EFFORT: stops wuauserv.
#   5. ESSENTIAL: purges C:\Windows\SoftwareDistribution\Download.
#      BEST EFFORT: purges the rest of SoftwareDistribution.
#   6. BEST EFFORT: purges C:\Windows\Prefetch and empties the Recycle Bin.
#   7. ESSENTIAL: removes downloaded installers from C:\Install by extension
#      (*.msi, *.msu, *.exe, *.appx, *.appxbundle, *.msix, *.msixbundle,
#      *.cab, *.zip). *.txt is deliberately NOT in that list.
#   8. Provisioner transcripts: KEPT by default; removed only when explicitly
#      opted in, and even then 998-cleanup.txt itself is excluded.
#   9. Prints free space, reclaimed space, total items deleted, then every
#      warning and every failure, and exits accordingly.
#
# WHAT IT VERIFIES
#   - The Windows Update download cache is re-scanned and must be empty (or
#     absent) afterwards - it is the single biggest consumer.
#   - The Application / System / Setup channels are re-read with
#     `wevtutil gli`; an unreadable count is a failure, and more than 50
#     records means the clear did not take. (A handful reappear immediately
#     because clearing is itself audited.)
#   - C:\Install is re-scanned for installer patterns; any leftover is named.
#   - EVERY purge returns a tally - removed / skipped / failed / ENUMERATION
#     ERRORS - and all of it is folded into the summary. The enumeration count
#     matters on its own: -ErrorAction SilentlyContinue is necessary here
#     (locked and access-denied children are normal) but on its own it is a
#     silent no-op generator, because a directory that could not be READ AT ALL
#     looks exactly like an empty one and "removed 0" then reads as "already
#     clean".
#   - The run-wide totals: zero items deleted anywhere, or zero space
#     reclaimed, each raise an explicit warning - that is the exact shape of a
#     silent no-op, even though a re-run over an already-clean image
#     legitimately produces both.
#
# FAILURE CONTRACT
#   FATAL     : exits 1 when any ESSENTIAL item fails - `wevtutil el`
#               returning nothing; Application/System/Setup refusing to clear,
#               reporting an unreadable count, or still holding >50 records;
#               the Windows Update download cache failing to purge, failing to
#               enumerate, or still containing items; the C:\Install installer
#               purge failing or leaving installer files behind; or any
#               unexpected exception in the outer catch.
#   LOUD SKIP : everything best-effort completes and still exits 0, but is
#               REPORTED as a WARNING rather than hidden - the temp purges, the
#               SoftwareDistribution remainder, prefetch, the Recycle Bin
#               (Clear-RecycleBin throws when already empty), a failure to stop
#               wuauserv, an unset TEMP variable, non-essential channels
#               refusing to clear (analytic/debug channels normally do), and
#               the zero-deleted / zero-reclaimed cases above.
#
# INPUTS (environment)
#   PACKER_CLEANUP_REMOVE_TRANSCRIPTS   1/true/yes to delete the C:\Install
#                                       *.txt provisioner transcripts.
#                                       Equivalent to -RemoveTranscripts.
#                                       Unset = transcripts are kept.
#
# NOTES
#   - IT MUST BE ABLE TO FAIL. The previous version set $ErrorActionPreference
#     to 'Continue', swallowed every inner error into a Write-Host, and ended
#     its outer catch with `exit 0` - a build in which nothing at all was
#     cleaned was indistinguishable from a clean one.
#   - PROVISIONER TRANSCRIPTS ARE DIAGNOSTIC EVIDENCE, NOT GARBAGE. Deleting
#     C:\Install\*.txt is how a failed Cloudbase-Init install once shipped with
#     no explanation of why (see 60-install-cloudbase-init.ps1). Removal is
#     opt-in, for a release image where the few KB actually matter. Downloaded
#     installers are hundreds of MB and ARE removed: they can be re-fetched on
#     demand, a transcript cannot.
#   - The packer-* exclusion when wiping Temp is load-bearing. Packer's
#     elevated_user provisioners re-source their environment-variable script
#     out of Temp between commands; wiping it mid-run fails the build. The
#     running script is protected for the same reason.
#   - Get-EventLog / Clear-EventLog do not exist in PowerShell 7 and only ever
#     covered a handful of classic logs, hence wevtutil.
#   - wevtutil's stderr is discarded rather than merged: merging native stderr
#     into the success stream raises NativeCommandError under
#     $ErrorActionPreference='Stop'. The exit code is the signal.
#
###############################################################################

[CmdletBinding()]
param(
    # Remove C:\Install\*.txt provisioner transcripts. OFF by default on
    # purpose - see the header. Opt in via -RemoveTranscripts or by setting
    # PACKER_CLEANUP_REMOVE_TRANSCRIPTS to 1/true/yes.
    [switch]$RemoveTranscripts
)

# Set preferences to control script behavior
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

if (-not $RemoveTranscripts -and $env:PACKER_CLEANUP_REMOVE_TRANSCRIPTS -match '^(1|true|yes)$') {
    $RemoveTranscripts = $true
}

# Directories whose contents are removed and then asserted empty.
$updateDownloadPath = "C:\Windows\SoftwareDistribution\Download"

# Extensions of downloaded installers that must not ship inside the template.
# NOTE: *.txt is deliberately absent - those are the transcripts.
$installerPatterns = @("*.msi", "*.msu", "*.exe", "*.appx", "*.appxbundle", "*.msix", "*.msixbundle", "*.cab", "*.zip")

# Event log channels that MUST come out clean. Everything else wevtutil
# reports is cleared best-effort (analytic/debug channels routinely refuse).
$essentialChannels = @("Application", "System", "Setup")

function Get-FreeSpace {
    [CmdletBinding()]
    [OutputType([int64])]
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$DriveLetter'" -ErrorAction Stop
    return [int64]$disk.FreeSpace
}

function Invoke-PathPurge {
    <#
        Deletes the contents of a directory, item by item, so one locked file
        does not abort the rest. Returns a summary object instead of throwing;
        the caller decides whether the leftovers matter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ExcludeName = @(),
        [string[]]$Include = @(),
        [string]$ProtectPath
    )

    $result = [pscustomobject]@{
        Path        = $Path
        Present     = $true
        Removed     = 0
        Skipped     = 0
        Failed      = 0
        EnumErrors  = 0
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  Path not present, nothing to do: $Path"
        $result.Present = $false
        return $result
    }

    # -ErrorAction SilentlyContinue on the enumeration is necessary (locked and
    # access-denied children are normal here) but on its own it is a silent
    # no-op generator: a directory that could not be read at all looks exactly
    # like an empty one. Capture the errors so the caller can say which.
    $enumErrors = @()
    if ($Include.Count -gt 0) {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -Include $Include -Recurse -ErrorAction SilentlyContinue -ErrorVariable +enumErrors)
    }
    else {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable +enumErrors)
    }
    $result.EnumErrors = @($enumErrors).Count
    if ($result.EnumErrors -gt 0) {
        Write-Host "  $($result.EnumErrors) error(s) while enumerating $Path; first: $(@($enumErrors)[0].Exception.Message)"
    }

    foreach ($item in $items) {
        $skip = $false

        foreach ($pattern in $ExcludeName) {
            if ($item.Name -like $pattern) {
                $skip = $true
                break
            }
        }

        # Never delete the script that is currently executing, nor the
        # directory it lives in - Packer runs provisioners out of Temp.
        if (-not $skip -and $ProtectPath -and $ProtectPath.StartsWith($item.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $skip = $true
        }

        if ($skip) {
            $result.Skipped++
            continue
        }

        # A recursive enumeration can hand us a child whose parent was already
        # deleted; that is not a failure.
        if (-not (Test-Path -LiteralPath $item.FullName)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $result.Removed++
        }
        catch {
            $result.Failed++
            Write-Host "  Could not remove $($item.FullName): $($_.Exception.Message)"
        }
    }

    Write-Host "  $Path : removed $($result.Removed), skipped $($result.Skipped), failed $($result.Failed), enumeration errors $($result.EnumErrors)"
    return $result
}

function Get-ChannelRecordCount {
    <#
        Returns the record count wevtutil reports for a channel, or -1 when it
        cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string]$Channel)

    # Note: stderr is discarded rather than merged - merging native stderr into
    # the success stream raises NativeCommandError under $ErrorActionPreference
    # = 'Stop' in Windows PowerShell. The exit code is the signal here.
    # An elevated scheduled task has no console, and native tools have been
    # observed returning nothing in that context (see 23-enable-ems-serial.ps1,
    # where bcdedit did exactly this). An empty read here would be counted as an
    # unreadable channel and reported as a cleanup FAILURE, blaming the event
    # log for what is really a capture problem. Retry through cmd.exe first.
    $info = @(& wevtutil.exe gli "$Channel" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  wevtutil gli '$Channel' exited $LASTEXITCODE"
        return -1
    }
    if ($info.Count -eq 0 -or ($info -join '').Trim() -eq '') {
        Write-Host "  wevtutil gli '$Channel' returned nothing; retrying via cmd.exe"
        $info = @(& cmd.exe /c "wevtutil.exe gli `"$Channel`"" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $info.Count -eq 0) {
            Write-Host "  wevtutil gli '$Channel' returned nothing even via cmd.exe"
            return -1
        }
    }

    foreach ($line in @($info)) {
        if ("$line" -match 'numberOfLogRecords:\s*(\d+)') {
            return [int]$Matches[1]
        }
    }

    return -1
}

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$transcriptStarted = $false
$exitCode = 0
$runningScript = $PSCommandPath
$totalRemoved = 0

function Register-PurgeResult {
    <#
        Fold one Invoke-PathPurge result into the run-wide tallies. Best-effort
        purges still have to answer for themselves: a purge that failed on every
        item, or could not enumerate its directory at all, produces a WARNING
        line rather than disappearing into `$null = ...`. Essential purges
        escalate the same conditions to a FAILURE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$Essential
    )

    $script:totalRemoved += [int]$Result.Removed

    $problems = @()
    if ($Result.Failed -gt 0) {
        $problems += "$($Result.Failed) item(s) could not be deleted"
    }
    if ($Result.EnumErrors -gt 0) {
        $problems += "$($Result.EnumErrors) error(s) reading the directory (contents may be untouched, not empty)"
    }

    foreach ($problem in $problems) {
        $message = "$Label ($($Result.Path)): $problem"
        if ($Essential) {
            $script:failures.Add($message)
        }
        else {
            $script:warnings.Add($message)
        }
    }
}

try {
    New-Item -Path "C:\Install" -ItemType Directory -Force | Out-Null
    Start-Transcript -Path "C:\Install\998-cleanup.txt" -Append
    $transcriptStarted = $true

    Write-Host "Proceeding with cleanup."
    Write-Host "Running script (protected from deletion): $runningScript"
    Write-Host "Remove provisioner transcripts: $RemoveTranscripts"

    $freeBefore = Get-FreeSpace -DriveLetter "C:"
    Write-Host ("Free space on C: before cleanup: {0:N2} GB" -f ($freeBefore / 1GB))

    # -- Windows temp files (best effort) -------------------------------------
    Write-Host "Deleting Windows temporary files..."
    Register-PurgeResult -Label "Windows temp" -Result (
        Invoke-PathPurge -Path "C:\Windows\Temp" -ExcludeName @("packer-*") -ProtectPath $runningScript)

    # -- User temp files (best effort) ----------------------------------------
    Write-Host "Deleting user temporary files..."
    if ($env:TEMP) {
        Register-PurgeResult -Label "user temp" -Result (
            Invoke-PathPurge -Path $env:TEMP -ExcludeName @("packer-*") -ProtectPath $runningScript)
    }
    else {
        $warnings.Add("TEMP environment variable is not set; user temp not cleaned")
    }

    # -- Event logs (essential) -----------------------------------------------
    # Get-EventLog / Clear-EventLog do not exist in PowerShell 7 and only ever
    # covered a handful of classic logs. wevtutil enumerates every channel.
    Write-Host "Clearing Event Logs..."
    $channels = @(& wevtutil.exe el 2>$null)
    if ($LASTEXITCODE -ne 0 -or $channels.Count -eq 0) {
        $failures.Add("wevtutil el failed (exit $LASTEXITCODE) - no event log channels enumerated")
    }
    else {
        $cleared = 0
        $refused = 0
        foreach ($channel in $channels) {
            $name = "$channel".Trim()
            if (-not $name) { continue }

            & wevtutil.exe cl "$name" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $cleared++
            }
            else {
                $refused++
                if ($essentialChannels -contains $name) {
                    $failures.Add("wevtutil cl '$name' exited $LASTEXITCODE")
                }
            }
        }
        Write-Host "  Channels enumerated: $($channels.Count), cleared: $cleared, refused: $refused"
        if ($refused -gt 0) {
            $warnings.Add("$refused event log channels refused to clear (analytic/debug channels normally do)")
        }

        # VERIFY: a cleared channel must report (near) zero records. A handful
        # of records reappear immediately because clearing is itself audited.
        foreach ($name in $essentialChannels) {
            $count = Get-ChannelRecordCount -Channel $name
            Write-Host "  Channel '$name' record count after clear: $count"
            if ($count -lt 0) {
                $failures.Add("Could not read record count for event log channel '$name'")
            }
            elseif ($count -gt 50) {
                $failures.Add("Event log channel '$name' still holds $count records after clear")
            }
        }
    }

    # -- Windows Update service (best effort, but the cache clear is not) -----
    Write-Host "Stopping Windows Update service..."
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction Stop
        Write-Host "  wuauserv stopped."
    }
    catch {
        $warnings.Add("Could not stop wuauserv: $($_.Exception.Message)")
        Write-Host "  Could not stop wuauserv: $($_.Exception.Message)"
    }

    # -- Windows Update cache (essential) -------------------------------------
    Write-Host "Clearing Windows Update cache..."
    Register-PurgeResult -Label "Windows Update download cache" -Essential -Result (
        Invoke-PathPurge -Path $updateDownloadPath)

    Write-Host "Removing leftover Windows update files..."
    Register-PurgeResult -Label "SoftwareDistribution" -Result (
        Invoke-PathPurge -Path "C:\Windows\SoftwareDistribution" -ExcludeName @("Download"))

    # VERIFY: the download cache is the single biggest consumer, so assert it.
    if (Test-Path -LiteralPath $updateDownloadPath) {
        $leftovers = @(Get-ChildItem -LiteralPath $updateDownloadPath -Force -Recurse -ErrorAction SilentlyContinue)
        if ($leftovers.Count -gt 0) {
            $failures.Add("$updateDownloadPath still contains $($leftovers.Count) items after cleanup")
        }
        else {
            Write-Host "  Verified empty: $updateDownloadPath"
        }
    }
    else {
        Write-Host "  Verified absent: $updateDownloadPath"
    }

    # -- Prefetch (best effort) -----------------------------------------------
    Write-Host "Deleting prefetch files..."
    Register-PurgeResult -Label "prefetch" -Result (
        Invoke-PathPurge -Path "C:\Windows\Prefetch")

    # -- Recycle Bin (best effort) --------------------------------------------
    Write-Host "Cleaning up the Recycle Bin..."
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  Recycle Bin cleared."
    }
    catch {
        # Clear-RecycleBin throws when the bin is already empty; that is fine.
        $warnings.Add("Clear-RecycleBin: $($_.Exception.Message)")
        Write-Host "  Clear-RecycleBin: $($_.Exception.Message)"
    }

    # -- Downloaded installers (essential) ------------------------------------
    # Hundreds of MB of MSI/EXE/APPX payload otherwise ships inside the
    # template. Transcripts (*.txt) are NOT in $installerPatterns.
    Write-Host "Removing downloaded installers from C:\Install..."
    Register-PurgeResult -Label "downloaded installers" -Essential -Result (
        Invoke-PathPurge -Path "C:\Install" -Include $installerPatterns -ProtectPath $runningScript)

    $installerLeftovers = @(Get-ChildItem -Path "C:\Install" -Force -Recurse -Include $installerPatterns -ErrorAction SilentlyContinue)
    if ($installerLeftovers.Count -gt 0) {
        $failures.Add("C:\Install still contains $($installerLeftovers.Count) installer files: $(($installerLeftovers | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')")
    }
    else {
        Write-Host "  Verified: no installer payload left in C:\Install"
    }

    # -- Provisioner transcripts (opt-in only) --------------------------------
    if ($RemoveTranscripts) {
        Write-Host "Removing installation transcripts (explicitly requested)..."
        # The transcript this script is writing stays open; leave it alone.
        Register-PurgeResult -Label "provisioner transcripts" -Result (
            Invoke-PathPurge -Path "C:\Install" -Include @("*.txt") -ExcludeName @("998-cleanup.txt"))
    }
    else {
        $keptTranscripts = @(Get-ChildItem -Path "C:\Install" -Filter "*.txt" -Force -ErrorAction SilentlyContinue)
        Write-Host "Keeping $($keptTranscripts.Count) provisioner transcript(s) in C:\Install for post-build diagnostics."
        Write-Host "  (set PACKER_CLEANUP_REMOVE_TRANSCRIPTS=1 to remove them)"
    }

    # -- Report ---------------------------------------------------------------
    $freeAfter = Get-FreeSpace -DriveLetter "C:"
    $reclaimed = $freeAfter - $freeBefore
    Write-Host ("Free space on C: after cleanup:  {0:N2} GB" -f ($freeAfter / 1GB))
    Write-Host ("Reclaimed: {0:N2} MB" -f ($reclaimed / 1MB))
    Write-Host "Items deleted across all purges: $totalRemoved"

    # "Cleanup completed" with nothing deleted anywhere is the exact shape of a
    # silent no-op. Neither of these is fatal on its own - a re-run over an
    # already-clean image legitimately removes nothing - but neither is allowed
    # to pass without being said out loud.
    if ($totalRemoved -eq 0) {
        $warnings.Add("No files were deleted by ANY purge. Either the image was already clean or nothing was actually cleaned; do not read the verifications below as evidence of work done.")
    }
    if ($reclaimed -le 0) {
        $warnings.Add(("No disk space was reclaimed (delta {0:N2} MB). Expect this only on a re-run over an already-clean image." -f ($reclaimed / 1MB)))
    }

    if ($warnings.Count -gt 0) {
        Write-Host "Best-effort cleanup warnings ($($warnings.Count)):"
        foreach ($warning in $warnings) {
            Write-Host "  WARNING: $warning"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "ESSENTIAL CLEANUP FAILED ($($failures.Count) problem(s)):"
        foreach ($failure in $failures) {
            Write-Host "  FAILURE: $failure"
        }
        $exitCode = 1
    }
    else {
        Write-Host "Cleanup completed and verified."
    }
}
catch {
    Write-Host "An unexpected error occurred during cleanup: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Host "Stop-Transcript: $($_.Exception.Message)"
        }
    }
}

exit $exitCode
