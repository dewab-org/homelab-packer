###############################################################################
# Name:             40-convert-evaluation-to-standard.ps1
# Description:      Converts a Windows Server *Standard Evaluation* install to
#                   licensed ServerStandard with DISM /Set-Edition, then reads
#                   the edition back from the live system to prove it. Exits 0
#                   unchanged when the OS is not an evaluation edition.
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\40-convert-evaluation-to-standard.txt.
#   2. Reads the running edition from the locale-independent EditionID
#      registry value, falling back to parsing `dism /online
#      /Get-CurrentEdition` if that value cannot be read.
#   3. Exits 0 when that edition is neither ServerStandardEval nor
#      ServerDatacenterEval - there is nothing to convert.
#   4. Rejects ServerDatacenterEval as out of scope (it needs a Datacenter key
#      and /Set-Edition:ServerDatacenter).
#   5. Requires a product key, from -ProductKey or WINDOWS_PRODUCT_KEY.
#   6. Runs dism /online /Set-Edition:ServerStandard with that key,
#      /AcceptEula and /NoRestart. The key itself is never echoed to the log.
#   7. Re-reads the edition and decides the outcome from what it finds.
#
# WHAT IT VERIFIES
#   - The edition is readable at all - EditionID, or failing that a dism
#     /Get-CurrentEdition that exits 0 with parseable output. Failure means
#     the edition is unknown, so no conversion decision can be trusted.
#   - dism /Set-Edition exits 0, 3010 or 1168. Anything else is a real DISM
#     failure. (3010 = reboot required; 1168 = ERROR_NOT_FOUND, routinely
#     returned when the change is staged and only completes on next boot.)
#   - The edition read back afterwards is exactly 'ServerStandard'. "No
#     longer an Eval string" is deliberately not accepted on its own: any
#     other edition means /Set-Edition did something other than what was
#     asked for.
#   - When the edition is still Eval, Test-RebootPending inspects the CBS and
#     WindowsUpdate RebootRequired keys plus PendingFileRenameOperations to
#     tell "staged, needs a reboot" apart from "silently did nothing".
#
# FAILURE CONTRACT
#   FATAL     : the edition cannot be read at all; the edition
#               is ServerDatacenterEval; no product key was supplied; dism
#               /Set-Edition exits outside {0,3010,1168}; the edition after
#               conversion is non-eval but is not 'ServerStandard'; the
#               edition is still Eval with neither a staged exit code nor a
#               pending reboot, which means the conversion did not happen.
#   LOUD SKIP : the running edition is not a Server evaluation edition - logs
#               "SKIPPED ... nothing to convert" and exits 0 unchanged.
#               Also: the change is staged but not applied (dism 3010/1168 or
#               a pending reboot) - prints an ACTION REQUIRED banner and exits
#               0, because only the next boot can complete it.
#
# INPUTS (environment)
#   WINDOWS_PRODUCT_KEY   KMS client setup key; the default for -ProductKey.
#                         No default - empty is fatal on an eval edition.
#   PACKER_DEBUG_HOLD     when set, sleeps 3600s on failure so the transcript
#                         can be read before Packer destroys the VM. Unset by
#                         default.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. No *.pkr.hcl in this repo references this
#     script, and nothing sets WINDOWS_PRODUCT_KEY. The repo owner has stated
#     that evaluation licensing is PREFERRED for these ephemeral test VMs, so
#     this exists as a deliberate library option, not as part of a build.
#   - Evaluation detection uses the EditionID registry value (with a DISM
#     fallback), NOT the old Win32_OperatingSystem OperatingSystemSKU
#     heuristic: Standard Eval and licensed Standard both report SKU 7, so the
#     SKU cannot tell them apart. EditionID is preferred over DISM because the
#     DISM label "Current Edition" is localised and unparseable on a
#     non-English image, while EditionID is the same token in every locale.
#   - The key MUST match the OS being built. The Server 2022 KMS client key
#     does not work on Server 2025, and this script is shared by both builds.
#   - The edition change only takes effect after a REBOOT, and this repo has
#     no windows-restart provisioner anywhere. A caller wiring this in must
#     add one immediately after this script and re-verify with
#     `dism /online /Get-CurrentEdition`, otherwise the template is captured
#     still running the evaluation edition.
#   - Scope is ServerStandardEval only.
###############################################################################

[CmdletBinding()]
param(
    [string]$ProductKey = $env:WINDOWS_PRODUCT_KEY
)

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# Start-Transcript throws if the directory is missing. Do not rely on an
# earlier provisioner having created C:\Install.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null

# Start transcript to log actions
$logPath = 'C:/Install/40-convert-evaluation-to-standard.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

function Get-CurrentWindowsEdition {
    # OperatingSystemSKU cannot distinguish evaluation from licensed media -
    # Standard Eval and licensed Standard both report SKU 7. The edition ID is
    # the only reliable signal.
    #
    # The registry is read FIRST because it is locale-independent: EditionID
    # holds the same token DISM prints as "Current Edition"
    # (ServerStandardEval / ServerStandard / ...), while the DISM label itself
    # is translated. On a non-English image the 'Current Edition :' pattern
    # below never matches, and the eval-token fallback after it only recognises
    # evaluation editions - so a localised licensed image used to reach the
    # final throw and fail a script that had nothing to do.
    $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
            -Name 'EditionID' -ErrorAction SilentlyContinue).EditionID
    if (-not [string]::IsNullOrWhiteSpace($editionId)) {
        return $editionId
    }

    # Fallback: ask DISM directly. Kept because EditionID is the one value that
    # could conceivably be absent, and losing the edition entirely is fatal.
    $output = & dism.exe /online /Get-CurrentEdition
    if ($LASTEXITCODE -ne 0) {
        throw ("EditionID is not readable from the registry and dism /online /Get-CurrentEdition failed with exit code ${LASTEXITCODE}:`n" + ($output -join "`n"))
    }

    $match = $output | Select-String -Pattern 'Current Edition\s*:\s*(?<edition>\S+)' | Select-Object -First 1
    if ($match) {
        return $match.Matches[0].Groups['edition'].Value
    }

    # Localised or unexpected output: still usable if the eval token is there.
    if (($output -join "`n") -match 'Server(Standard|Datacenter)Eval') {
        return $Matches[0]
    }

    throw ("Could not read the current Windows edition from the registry or from DISM output:`n" + ($output -join "`n"))
}

function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { return $true }
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pendingRenames = (Get-ItemProperty -Path $sessionManager -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pendingRenames) { return $true }

    return $false
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Host "Running OS: $($os.Caption) (build $($os.BuildNumber))"

    Write-Host "Checking if Windows is in evaluation mode..."
    $edition = Get-CurrentWindowsEdition
    Write-Host "Current edition: $edition"

    if ($edition -notmatch 'ServerStandardEval|ServerDatacenterEval') {
        Write-Host "SKIPPED: edition '$edition' is not a Server evaluation edition, so there is nothing to convert. No change was made."
        exit 0
    }

    if ($edition -match 'ServerDatacenterEval') {
        throw "Edition '$edition' is a Datacenter Evaluation. This script only converts ServerStandardEval to ServerStandard; converting Datacenter requires a Datacenter key and /Set-Edition:ServerDatacenter."
    }

    if ([string]::IsNullOrWhiteSpace($ProductKey)) {
        throw "No product key supplied. Pass -ProductKey or set WINDOWS_PRODUCT_KEY to the KMS client setup key matching this OS (the Server 2022 key does not work on Server 2025)."
    }

    Write-Host "Evaluation edition detected. Converting to ServerStandard."
    $dismArgs = @('/online', "/Set-Edition:ServerStandard", "/ProductKey:$ProductKey", '/AcceptEula', '/NoRestart')
    # Do not log the key itself.
    Write-Host "Executing: dism.exe /online /Set-Edition:ServerStandard /ProductKey:<redacted> /AcceptEula /NoRestart"

    $dismOutput = & dism.exe @dismArgs
    $dismExit = $LASTEXITCODE
    Write-Host ($dismOutput -join "`n")
    Write-Host "dism /Set-Edition exit code: $dismExit"

    # 0     = success
    # 3010  = success, reboot required
    # 1168  = ERROR_NOT_FOUND, routinely returned by /Set-Edition when the
    #         change is staged and only completes on the next boot
    $rebootRequiredCodes = @(3010, 1168)
    if ($dismExit -ne 0 -and $dismExit -notin $rebootRequiredCodes) {
        throw "dism /online /Set-Edition:ServerStandard failed with exit code $dismExit."
    }

    # Verify the effect: read the edition back from the live system.
    $editionAfter = Get-CurrentWindowsEdition
    Write-Host "Edition after conversion: $editionAfter"

    if ($editionAfter -notlike '*Eval*') {
        # Not-an-eval-edition is necessary but not sufficient: the only
        # acceptable outcome of /Set-Edition:ServerStandard is ServerStandard.
        if ($editionAfter -ne 'ServerStandard') {
            throw "dism /Set-Edition:ServerStandard reported success but the edition is now '$editionAfter', expected 'ServerStandard'."
        }
        Write-Host "Conversion verified: edition is now '$editionAfter'."
        exit 0
    }

    # Still an evaluation edition. That is only acceptable when the change is
    # genuinely staged for the next boot.
    $rebootPending = Test-RebootPending
    if ($dismExit -in $rebootRequiredCodes -or $rebootPending) {
        Write-Host "***************************************************************"
        Write-Host "*** WARNING: EDITION CONVERSION IS STAGED, NOT COMPLETE     ***"
        Write-Host "*** The running edition is still '$editionAfter'."
        Write-Host "*** (dism exit $dismExit, RebootPending=$rebootPending)"
        Write-Host "*** ACTION REQUIRED: the VM must be rebooted to finish the  ***"
        Write-Host "*** edition change. There is no windows-restart provisioner ***"
        Write-Host "*** in this repo - the caller MUST add one immediately      ***"
        Write-Host "*** after this script and re-verify with:                   ***"
        Write-Host "***     dism /online /Get-CurrentEdition                    ***"
        Write-Host "*** WITHOUT THAT REBOOT THE TEMPLATE IS CAPTURED STILL      ***"
        Write-Host "*** RUNNING THE EVALUATION EDITION.                         ***"
        Write-Host "***************************************************************"
        exit 0
    }

    throw "dism reported exit code $dismExit but the edition is still '$editionAfter' and no reboot is pending - the conversion did not happen."
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
