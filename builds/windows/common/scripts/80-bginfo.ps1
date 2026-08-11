###############################################################################
# Name:             80-bginfo.ps1
# Description:      Obtain Bginfo64.exe and a .bgi config, then register BGInfo
#                   in the HKLM Run key so every future logon paints the
#                   desktop wallpaper. Cosmetic, so it degrades loudly.
# Author:           Daniel Whicker
# Date:             2021-11-09
###############################################################################
#
# WHAT IT DOES
#   1. Starts the transcript at C:/Install/80-bginfo.txt.
#   2. Resolves the .bgi config URL: BGINFO_CONFIG_URL wins, otherwise
#      <PACKER_FILES_BASEURL>/windows/myconfig.bgi. Neither set = LOUD SKIP.
#   3. Creates C:\BGInfo.
#   4. Resolves Bginfo64.exe, in this order:
#        0. an existing install (five well-known paths, then a recursive
#           search of both Program Files trees),
#        1. upstream Sysinternals, direct file: live.sysinternals.com,
#        2. upstream Sysinternals zip: download.sysinternals.com/files/
#           BGInfo.zip, extracted to C:\BGInfo\Bginfo64.exe,
#        3. winget (Microsoft.Sysinternals.BGInfo), then re-locate on disk,
#        4. an optional lab mirror (BGINFO_BINARY_URL, or
#           <PACKER_FILES_BASEURL>/windows/Bginfo64.exe) for a build with no
#           upstream egress.
#      EVERY SOURCE IS INDIVIDUALLY ISOLATED in its own try/catch, so a source
#      that throws (DNS failure, TLS error, winget writing to stderr) falls
#      through to the next instead of aborting the script. None of them is
#      allowed to fail silently: each prints why.
#   5. Downloads the .bgi config to C:\BGInfo\logon.bgi.
#   6. Writes HKLM\...\CurrentVersion\Run\BgInfo and reads it back.
#   7. Best-effort: runs BGInfo once for the current build account.
#
# WHAT IT VERIFIES
#   - Any downloaded binary is >= 10240 bytes AND starts with an MZ header. A
#     captive-portal or proxy error page saved as .exe passes a size check on
#     its own; a rejected file is deleted and the source moves on.
#   - winget is judged by exit code (0, 0x8A15002B, 0x8A150061), and even on
#     success Bginfo64.exe must then be FOUND ON DISK - "winget reported
#     success but Bginfo64.exe is nowhere on disk" discards that source.
#   - The downloaded .bgi exists and is non-empty.
#   - The HKLM Run value is read back and compared to what was written. This is
#     the one durable effect of the whole script and the one thing that must
#     never be assumed.
#
# FAILURE CONTRACT
#   FATAL     : the HKLM Run entry cannot be written or does not read back
#               (Register-BGInfoStartup throws: missing Run key, failed write,
#               or a mismatched read-back); C:\BGInfo cannot be created; any
#               unexpected error outside the isolated blocks. Exits 1.
#   LOUD SKIP : exits 0 after a banner, because wallpaper is cosmetic and a
#               fully-patched template must not be thrown away over it -
#               (a) no config URL configured, (b) BGInfo could not be obtained
#               from ANY source, (c) the .bgi could not be fetched. Every one
#               of those banners states "NO BGInfo Run entry was written" in so
#               many words, so a transcript can never be misread as "BGInfo
#               configured". Separately, BGInfo failing to paint the build
#               account's wallpaper warns but does not fail: that profile is
#               discarded, and the verified Run entry is what future logons
#               use.
#
# INPUTS (environment)
#   BGINFO_CONFIG_URL     Full URL to the .bgi file. Takes precedence.
#   PACKER_FILES_BASEURL  Base URL; the config is fetched from
#                         <base>/windows/myconfig.bgi and the optional binary
#                         mirror from <base>/windows/Bginfo64.exe.
#   BGINFO_BINARY_URL     Full URL to Bginfo64.exe for an air-gapped build.
#   PACKER_DEBUG_HOLD     Optional. On a fatal error, sleep 3600s before
#                         exiting so the VM can be inspected.
#
# NOTES
#   - THIS SCRIPT HAD NEVER WORKED. Set-Registry was called with NO ARGUMENTS
#     while its own param() block declared $bgiRegistryKey / $bgiRegistryValue,
#     so those parameters shadowed the script-scope variables with empty
#     strings and New-ItemProperty -Path '' threw on every single build. The
#     startup entry was never written, on any template, for years. Hence the
#     read-back assertion.
#   - Scope: the Run entry is written to HKLM (all users), which is what makes
#     it survive the disposable build account. The Invoke-BGInfo call at the
#     end only paints the CURRENT build user's wallpaper.
#   - Bginfo64.exe is pulled fresh from upstream on every build, so the
#     template ships the current version and nothing has to be pre-staged.
#     live.sysinternals.com is a WebDAV-ish share some proxies mangle, which is
#     why the plain HTTPS zip is tried second.
#   - Chocolatey is deliberately absent from the resolution order: it is not
#     installed on these templates, so the old "51-install-chocolatey-apps will
#     have put it there" assumption threw on every build.
#   - winget writes progress to stderr, and merging that into the success
#     stream raises NativeCommandError under $ErrorActionPreference='Stop' -
#     which turned any noisy winget run into a build failure over wallpaper.
#     The preference is dropped to 'Continue' for the duration of that call.
#   - Show-Log only writes to the host. It used to also Add-Content to
#     $logFile, the same path Start-Transcript holds open, so every call failed
#     with a sharing violation and aborted the script.
#   - The .bgi URL used to be a hardcoded personal FileBrowser share link with
#     an access token in the path. That token is out of the repo; supply the
#     location through the environment instead.

###############################################################################
# Variables
###############################################################################

$configDir = "C:\BGInfo"
$configFile = "$configDir\logon.bgi"
$bgiRegistryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$bgiRegistryName = "BgInfo"
$logFile = "C:/Install/80-bginfo.txt"

# Program Files roots come from the environment rather than being hardcoded to
# C:, so an image whose Program Files is not on C: is still searched correctly.
# ${env:ProgramFiles(x86)} is the 32-bit root; on a 32-bit host it is unset, so
# empty entries are filtered out.
# The @() wrapper matters: a single surviving root would otherwise be a bare
# string, and the .Count checks below would be reading a string's length rather
# than an array's element count.
$programFilesRoots = @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

# Well-known locations an existing Bginfo64.exe may already occupy, in the same
# probe order as before: both roots' BGInfo\, then both roots' Sysinternals\,
# then the directory this script downloads into.
$bgiCandidatePaths = @(
    foreach ($subDir in @('BGInfo', 'Sysinternals')) {
        foreach ($root in $programFilesRoots) {
            Join-Path $root "$subDir\Bginfo64.exe"
        }
    }
    "C:\BGInfo\Bginfo64.exe"
)

###############################################################################
# Functions
###############################################################################

function Show-Log {
    [CmdletBinding()]
    param (
        [string]$message
    )
    # Write-Host only. This used to also Add-Content to $logFile, but
    # Start-Transcript further down opens that same path and holds it, so every
    # call failed with "The process cannot access the file ... because it is
    # being used by another process" and aborted the script. The transcript
    # already captures Write-Host, so the second write was redundant as well as
    # broken.
    Write-Host $message
}

function Get-BGInfoConfigUrl {
    # Explicit full URL wins; otherwise derive it from the shared files base.
    if (-not [string]::IsNullOrWhiteSpace($env:BGINFO_CONFIG_URL)) {
        return $env:BGINFO_CONFIG_URL
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PACKER_FILES_BASEURL)) {
        return ($env:PACKER_FILES_BASEURL.TrimEnd('/') + '/windows/myconfig.bgi')
    }
    return $null
}

function Get-BGInfoBinaryUrl {
    # Explicit full URL wins; otherwise derive it from the shared files base.
    if (-not [string]::IsNullOrWhiteSpace($env:BGINFO_BINARY_URL)) {
        return $env:BGINFO_BINARY_URL
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PACKER_FILES_BASEURL)) {
        return ($env:PACKER_FILES_BASEURL.TrimEnd('/') + '/windows/Bginfo64.exe')
    }
    return $null
}

function Find-InstalledBGInfo {
    # Look for a Bginfo64.exe that is already on disk: the well-known paths
    # first, then a recursive sweep of the Program Files trees. Returns the
    # path, or $null.
    #
    # This runs twice - once before any download source is tried, and once
    # after winget reports an install - so it is one function rather than two
    # copies of the same search that could drift apart. $Label only changes the
    # wording of the log line.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Label)

    foreach ($candidate in $bgiCandidatePaths) {
        if (Test-Path $candidate) {
            Show-Log "Found $Label BGInfo at $candidate"
            return $candidate
        }
    }

    if ($programFilesRoots.Count -gt 0) {
        $match = Get-ChildItem -Path $programFilesRoots -Filter "Bginfo64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) {
            Show-Log "Found $Label BGInfo at $($match.FullName)"
            return $match.FullName
        }
    }

    return $null
}

function Find-BGInfoPath {
    # Resolution order:
    #
    #   0. an existing install already on the image,
    #   1. upstream Sysinternals, direct file (live.sysinternals.com),
    #   2. upstream Sysinternals zip (download.sysinternals.com),
    #   3. winget (Microsoft.Sysinternals.BGInfo),
    #   4. an optional lab mirror, for a build with no upstream egress.
    #
    # Chocolatey is deliberately absent: it is not installed on these templates
    # by choice, so the old "51-install-chocolatey-apps will have put it there"
    # assumption threw on every build.
    #
    # Returns $null when the binary cannot be obtained -- BGInfo is cosmetic, and
    # the caller turns that into a LOUD skip rather than failing the whole
    # template. Every individual source is wrapped so that a source that errors
    # (rather than merely 404s) also degrades to the next source instead of
    # aborting the script.
    $existing = Find-InstalledBGInfo -Label 'existing'
    if ($existing) {
        return $existing
    }

    $target = "C:\BGInfo\Bginfo64.exe"
    $targetDir = Split-Path $target -Parent
    try {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        if (-not (Test-Path $targetDir)) {
            throw "directory $targetDir does not exist after New-Item"
        }
    }
    catch {
        Show-Log "Cannot create $targetDir ($($_.Exception.Message)); no download source can be used."
        return $null
    }

    # Each source is isolated: a source that throws (DNS failure, TLS error,
    # winget writing to stderr under $ErrorActionPreference='Stop', ...) must
    # fall through to the next source, not abort the script. Silence is the only
    # thing that is not tolerated - every failed source prints why.
    # 1) Upstream Sysinternals, direct single file. Preferred: no archive, no
    #    package manager, and it is always the current build.
    try {
        if (Get-BGInfoFromUrl -Url 'https://live.sysinternals.com/Bginfo64.exe' -Destination $target -Source 'upstream (live.sysinternals.com)') {
            return $target
        }
    }
    catch {
        Show-Log "  source errored: $($_.Exception.Message)"
    }

    # 2) Upstream Sysinternals zip. live.sysinternals.com is a WebDAV-ish share
    #    that some proxies mangle; the zip on download.sysinternals.com is a
    #    plain HTTPS object and usually survives where the direct file does not.
    try {
        if (Get-BGInfoFromZip -Url 'https://download.sysinternals.com/files/BGInfo.zip' -Destination $target) {
            return $target
        }
    }
    catch {
        Show-Log "  source errored: $($_.Exception.Message)"
    }

    # 3) winget, if this image has it (53-install-winget runs before this).
    try {
        if (Install-BGInfoViaWinget) {
            $wingetInstalled = Find-InstalledBGInfo -Label 'winget-installed'
            if ($wingetInstalled) {
                return $wingetInstalled
            }
            Show-Log "  winget reported success but Bginfo64.exe is nowhere on disk; ignoring that source"
        }
    }
    catch {
        Show-Log "  source errored: $($_.Exception.Message)"
    }

    # 4) Optional lab-mirror override, for a build with no upstream egress.
    try {
        $mirrorUrl = Get-BGInfoBinaryUrl
        if ([string]::IsNullOrWhiteSpace($mirrorUrl)) {
            Show-Log "No lab mirror configured (BGINFO_BINARY_URL / PACKER_FILES_BASEURL unset); skipping that source"
        }
        elseif (Get-BGInfoFromUrl -Url $mirrorUrl -Destination $target -Source 'lab file mirror') {
            return $target
        }
    }
    catch {
        Show-Log "  source errored: $($_.Exception.Message)"
    }

    return $null
}

function Test-BGInfoBinary {
    # A captive portal or proxy error page saved as .exe passes a size check, so
    # require an actual PE header before trusting the file.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return $false }
    $length = (Get-Item $Path).Length
    if ($length -lt 10240) {
        Show-Log "  rejected: file is implausibly small ($length bytes)"
        return $false
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 2
        [void]$stream.Read($header, 0, 2)
    }
    finally {
        $stream.Dispose()
    }

    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        Show-Log "  rejected: not a PE executable (no MZ header)"
        return $false
    }
    return $true
}

function Get-BGInfoFromUrl {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Source
    )

    Show-Log "Trying BGInfo from $Source"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
    }
    catch {
        Show-Log "  failed: $($_.Exception.Message)"
        Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        return $false
    }

    if (-not (Test-BGInfoBinary -Path $Destination)) {
        Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        return $false
    }

    Show-Log "  ok: downloaded to $Destination"
    return $true
}

function Get-BGInfoFromZip {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Show-Log "Trying BGInfo from upstream zip ($Url)"
    $zip = Join-Path $env:TEMP "BGInfo.zip"
    $extract = Join-Path $env:TEMP "BGInfo-extract"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing -TimeoutSec 120
        if (Test-Path $extract) { Remove-Item -Path $extract -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $found = Get-ChildItem -Path $extract -Filter "Bginfo64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            Show-Log "  failed: Bginfo64.exe not present in the archive"
            return $false
        }
        Copy-Item -Path $found.FullName -Destination $Destination -Force
    }
    catch {
        Show-Log "  failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $extract -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-BGInfoBinary -Path $Destination)) {
        Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        return $false
    }

    Show-Log "  ok: extracted to $Destination"
    return $true
}

function Install-BGInfoViaWinget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Show-Log "winget not available; skipping that source"
        return $false
    }

    Show-Log "Trying BGInfo via winget (Microsoft.Sysinternals.BGInfo)"

    # Merging a native command's stderr into the success stream raises
    # NativeCommandError while $ErrorActionPreference is 'Stop' in Windows
    # PowerShell, and winget writes progress to stderr. That turned any noisy
    # winget run into a thrown exception that failed the whole build over
    # wallpaper. Drop the preference to 'Continue' for the duration of the call
    # and judge it solely by its exit code.
    $previousPreference = $ErrorActionPreference
    $exitCode = $null
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = & winget.exe install --id Microsoft.Sysinternals.BGInfo --exact --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        Show-Log "  failed: winget could not be run: $($_.Exception.Message)"
        return $false
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    foreach ($line in @($output)) {
        Show-Log "  winget: $line"
    }

    # 0 = installed, 0x8A15002B = no applicable update, 0x8A150061 = already installed
    if ($exitCode -notin @(0, -1978335189, -1978335135)) {
        Show-Log "  failed: winget exited $exitCode"
        return $false
    }
    Show-Log "  winget exited $exitCode"
    return $true
}

function Get-ConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Show-Log "Downloading config file from $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not (Test-Path $Destination)) {
        throw "Download of $Url reported success but $Destination does not exist"
    }
    $size = (Get-Item $Destination).Length
    if ($size -eq 0) {
        throw "Downloaded $Destination is empty"
    }
    Show-Log "Downloaded $Destination ($size bytes)"
}

function Register-BGInfoStartup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$RegistryKey,
        [Parameter(Mandatory = $true)][string]$RegistryName,
        [Parameter(Mandatory = $true)][string]$RegistryValue
    )

    Show-Log "Configuring registry value $RegistryKey\$RegistryName"
    if (-not (Test-Path $RegistryKey)) {
        throw "Run key $RegistryKey does not exist"
    }

    $existing = Get-ItemProperty -Path $RegistryKey -Name $RegistryName -ErrorAction SilentlyContinue
    if ($existing) {
        Show-Log "Removing existing $RegistryName value"
        Remove-ItemProperty -Path $RegistryKey -Name $RegistryName -Force
    }

    Show-Log "Creating $RegistryName value"
    New-ItemProperty -Path $RegistryKey -Name $RegistryName -PropertyType String -Value $RegistryValue -Force | Out-Null

    # Read it back. The whole point of this script is this one value, and for
    # years it was never actually written.
    $actual = (Get-ItemProperty -Path $RegistryKey -Name $RegistryName -ErrorAction SilentlyContinue).$RegistryName
    if ($actual -ne $RegistryValue) {
        throw "Verification failed for $RegistryKey\$RegistryName - expected '$RegistryValue', found '$actual'"
    }
    Show-Log "Verified $RegistryKey\$RegistryName = $actual"
}

function Invoke-BGInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$BgiPath,
        [Parameter(Mandatory = $true)][string]$ConfigFile
    )
    Show-Log "Running BGInfo with the downloaded configuration"
    $global:LASTEXITCODE = 0
    & $BgiPath $ConfigFile /timer:0 /nolicprompt
    # BGInfo is a GUI app and its exit code is not a reliable success signal,
    # so this is informational only - the Run key is the durable effect and it
    # has already been verified by the time this runs. $LASTEXITCODE is reset
    # first so this line cannot report some earlier command's code.
    Show-Log "BGInfo exited with code $LASTEXITCODE (informational only; the verified HKLM Run entry is what future logons use)"
}

###############################################################################
# Main
###############################################################################

# Terminate entire script if an exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path $logFile -Append

try {
    $configUrl = Get-BGInfoConfigUrl
    if ([string]::IsNullOrWhiteSpace($configUrl)) {
        Show-Log "*******************************************************************"
        Show-Log "WARNING: no BGInfo config URL configured."
        Show-Log "WARNING: set BGINFO_CONFIG_URL (full URL to the .bgi file) or"
        Show-Log "WARNING: PACKER_FILES_BASEURL (<base>/windows/myconfig.bgi)."
        Show-Log "WARNING: skipping BGInfo setup - wallpaper is cosmetic, the"
        Show-Log "WARNING: template is otherwise unaffected."
        Show-Log "*******************************************************************"
        Exit 0
    }

    Show-Log "Creating directory $configDir"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    if (-not (Test-Path -Path $configDir)) {
        throw "Could not create $configDir"
    }

    # Any unexpected error while sourcing the binary degrades to the loud skip
    # below. BGInfo must never be the reason a fully-patched template is thrown
    # away, but it must also never be skipped quietly.
    $bgiPath = $null
    try {
        $bgiPath = Find-BGInfoPath
    }
    catch {
        Show-Log "Unexpected error while locating BGInfo: $($_.Exception.Message)"
        $bgiPath = $null
    }

    if ([string]::IsNullOrWhiteSpace($bgiPath)) {
        # Loud skip, not a silent one, and not a build failure: BGInfo is desktop
        # wallpaper. Failing a fully-patched template over it would be worse than
        # shipping without it. Stage Bginfo64.exe on the lab file mirror (or set
        # BGINFO_BINARY_URL) to enable it.
        Show-Log "*******************************************************************"
        Show-Log "WARNING: BGInfo binary could not be located or downloaded."
        Show-Log "WARNING: skipping BGInfo setup entirely - wallpaper is cosmetic."
        Show-Log "WARNING: to enable, publish Bginfo64.exe under PACKER_FILES_BASEURL"
        Show-Log "WARNING: (as <base>/windows/Bginfo64.exe) or set BGINFO_BINARY_URL."
        Show-Log "WARNING: NO BGInfo Run entry was written - future logons get no wallpaper."
        Show-Log "*******************************************************************"
        Exit 0
    }
    Show-Log "Using BGInfo at $bgiPath"

    # Download failures are non-fatal (cosmetic), but they are shouted about.
    $haveConfig = $false
    try {
        Get-ConfigFile -Url $configUrl -Destination $configFile
        $haveConfig = $true
    }
    catch {
        Show-Log "*******************************************************************"
        Show-Log "WARNING: could not fetch the BGInfo config from $configUrl"
        Show-Log "WARNING: $($_.Exception.Message)"
        Show-Log "WARNING: skipping BGInfo setup - wallpaper is cosmetic."
        Show-Log "WARNING: NO BGInfo Run entry was written - future logons get no wallpaper."
        Show-Log "*******************************************************************"
    }

    if (-not $haveConfig) {
        Exit 0
    }

    # From here on the script IS claiming to have configured BGInfo, so the one
    # durable effect - the HKLM Run entry - is written, read back and asserted.
    # A failure in Register-BGInfoStartup is fatal on purpose: unlike a missing
    # binary, it means the registry write itself did not take, which is the
    # exact class of bug this script was rewritten to stop hiding.
    $bgiRegistryValue = "`"$bgiPath`" `"$configFile`" /timer:0 /nolicprompt"
    Register-BGInfoStartup -RegistryKey $bgiRegistryKey -RegistryName $bgiRegistryName -RegistryValue $bgiRegistryValue

    # Painting the CURRENT (disposable build) user's wallpaper is pure cosmetics
    # on a profile that is about to be discarded, so it is best-effort: loud on
    # failure, never fatal.
    try {
        Invoke-BGInfo -BgiPath $bgiPath -ConfigFile $configFile
    }
    catch {
        Show-Log "*******************************************************************"
        Show-Log "WARNING: BGInfo could not be run for the build account:"
        Show-Log "WARNING: $($_.Exception.Message)"
        Show-Log "WARNING: this only affects the disposable build profile. The verified"
        Show-Log "WARNING: HKLM Run entry above is what future logons use, so BGInfo"
        Show-Log "WARNING: setup is still in place."
        Show-Log "*******************************************************************"
    }

    # Explicit success code, matching the three LOUD SKIP exits above. Without
    # it the script fell off the end of the try block and Packer's default
    # execute_command ('exit $LastExitCode') propagated whatever Bginfo64.exe -
    # a GUI app whose exit code is explicitly documented here as meaningless -
    # happened to leave behind. That contradicts the stated contract that
    # BGInfo must never be the reason a fully-patched template is thrown away.
    Exit 0
}
catch {
    Show-Log "Something went wrong: $($_.Exception.Message)"

    if ($env:PACKER_DEBUG_HOLD) {
        Show-Log "PACKER_DEBUG_HOLD set - sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    Exit 1
}
finally {
    Stop-Transcript
}
