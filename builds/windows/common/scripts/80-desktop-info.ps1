###############################################################################
# Name:             80-desktop-info.ps1
# Description:      Paints host details onto the desktop wallpaper - hostname,
#                   IP, MAC, DNS servers and disks - and installs a logon task
#                   that redraws them, so a clone shows ITS OWN details.
# Author:           Daniel Whicker
# Date:             2026-08-12
###############################################################################
#
# WHY THIS REPLACES BGINFO
#
# This used to be 80-bginfo.ps1, which downloaded Sysinternals BGInfo and a
# .bgi config. That arrangement had three problems, and all of them are gone:
#
#   1. A .bgi is a BINARY file that can only be produced by BGInfo's GUI. It
#      cannot be reviewed, diffed, or generated in CI - it is an opaque blob
#      that has to be authored by hand once and then hosted somewhere forever.
#   2. Hosting it meant a lab file share plus an access token, and the token
#      that used to be embedded in the URL was committed to git.
#   3. BGInfo itself had to be fetched from Sysinternals at build time, which
#      this lab's build VLAN could not always reach.
#
# The fields wanted here are a dozen lines of PowerShell against the same WMI
# and networking data BGInfo reads. Doing it in-repo means the whole thing is
# plain text under review, with no download, no token and no binary.
#
# WHAT IT DOES
#   1. Skips loudly on Server Core, which has no desktop to paint.
#   2. Writes C:\ProgramData\DesktopInfo\Update-DesktopInfo.ps1, which renders
#      the wallpaper from live system state.
#   3. Runs it once now to a throwaway path, purely to prove the renderer
#      works while the build log is still watching, then deletes the output.
#   4. Registers the 'Desktop-Info-Refresh' scheduled task with an AT LOGON
#      trigger so the wallpaper is REDRAWN for whoever logs on, into THAT
#      user's LOCALAPPDATA.
#
# WHY A LOGON TASK AND NOT A STATIC IMAGE
#   The same trap as the WinRM certificate: anything rendered at build time
#   carries the BUILD VM's identity. A clone renamed by Cloudbase-Init, given a
#   new IP by DHCP and a resized disk would sit there displaying the values of
#   a machine that no longer exists - and looking authoritative while doing it.
#   Wrong information presented confidently is worse than none, so the image is
#   regenerated at every logon from live state.
#
# FIELDS RENDERED
#   Host name, OS caption and build, IPv4 address(es) with interface name,
#   MAC address(es), DNS servers, and every fixed disk with size, free space
#   and percentage used.
#
# WHAT IT VERIFIES
#   - The renderer script is on disk after being written.
#   - Running it produced a bitmap, and the bitmap is a plausible size (a
#     zero-byte or truncated file would set a black wallpaper and look like a
#     rendering that simply had nothing to say).
#   - The scheduled task is registered and not Disabled. Without it the
#     wallpaper silently freezes at the template's values on every clone, which
#     is the exact failure this design exists to avoid.
#
# FAILURE CONTRACT
#   FATAL     : the renderer cannot be written, the first render produces no
#               usable bitmap, or the logon task will not register. Each of
#               those means clones would show stale or missing information
#               while the build claimed success.
#   LOUD SKIP : Server Core - no desktop exists, so there is nothing to paint.
#               Prints a banner saying no wallpaper was configured and exits 0.
#
# NOTES
#   - The wallpaper is set per-user (HKCU + SystemParametersInfo), which is why
#     the refresh runs at LOGON in the user's own context rather than as SYSTEM
#     at startup. A SYSTEM-context task can render the image but cannot apply it
#     to an interactive session.
#   - Rendering uses System.Drawing, present on Desktop Experience images. The
#     Core skip above means it is never loaded where it might be absent.
###############################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$infoDir = 'C:\ProgramData\DesktopInfo'
$renderer = Join-Path $infoDir 'Update-DesktopInfo.ps1'
# The shared path the renderer USED to write to. Kept only so the build can
# assert nothing is left there - see the removal below. The real bitmap lives
# in each user's LOCALAPPDATA.
$bitmap = Join-Path $infoDir 'desktopinfo.bmp'
$taskName = 'Desktop-Info-Refresh'

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/80-desktop-info.txt' -Append

function Test-DesktopExperience {
    # Server Core has no shell to show a wallpaper. Same detection used by
    # 53-install-winget.ps1 for the same class of reason.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $type = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -Name 'InstallationType' -ErrorAction Stop).InstallationType
    }
    catch {
        Write-Host "Could not read InstallationType ($($_.Exception.Message)); assuming a desktop is present."
        return $true
    }
    Write-Host "Windows InstallationType: $type"
    return ($type -ne 'Server Core')
}

try {
    if (-not (Test-DesktopExperience)) {
        Write-Host ""
        Write-Host "*******************************************************************"
        Write-Host "*** SKIPPED: no desktop on this image"
        Write-Host "***"
        Write-Host "*** Server Core has no wallpaper to paint, so NO desktop info was"
        Write-Host "*** configured and NO scheduled task was registered."
        Write-Host "***"
        Write-Host "*** This is a platform boundary, not a build failure."
        Write-Host "*******************************************************************"
        Write-Host ""
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $infoDir | Out-Null

    # Single-quoted here-string: nothing below is expanded now. It is evaluated
    # on the guest, at logon, against that machine's live state.
    $payload = @'
###############################################################################
# Update-DesktopInfo.ps1 - installed by 80-desktop-info.ps1
#
# Renders host details onto a bitmap and sets it as the current user's
# wallpaper. Runs at every logon so a clone shows ITS OWN hostname, address and
# disks rather than the values of the template it came from.
###############################################################################
[CmdletBinding()]
param(
    # Defaults PER-USER, and that is load-bearing. This runs at logon under a
    # LIMITED token (see the principal on the scheduled task). A file created
    # by SYSTEM under C:\ProgramData cannot be overwritten by that token -
    # ProgramData's inherited ACL lets Users CREATE files but not modify ones
    # another principal owns. Writing the shared path would therefore throw at
    # every single logon, and the desktop would keep displaying whatever the
    # TEMPLATE rendered: wrong hostname, wrong IP, wrong disks, all looking
    # perfectly authoritative. Per-user also matches what a wallpaper is.
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:SystemRoot 'Temp' }
    $OutputPath = Join-Path $base 'DesktopInfo\desktopinfo.bmp'
}
Add-Type -AssemblyName System.Drawing

function Get-InfoLineList {
    $lines = New-Object System.Collections.Generic.List[string]

    $os = Get-CimInstance Win32_OperatingSystem
    $lines.Add("Host Name    : $env:COMPUTERNAME")
    $lines.Add("OS           : $($os.Caption) (build $($os.BuildNumber))")
    $lines.Add("Boot Time    : $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("")

    # IPv4 addresses, skipping loopback and APIPA, labelled by interface.
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' })
    if ($addresses.Count -eq 0) {
        $lines.Add("IP Address   : (none)")
    }
    else {
        $first = $true
        foreach ($a in $addresses) {
            $label = if ($first) { "IP Address   : " } else { "               " }
            $lines.Add("$label$($a.IPAddress)/$($a.PrefixLength)  [$($a.InterfaceAlias)]")
            $first = $false
        }
    }

    # MAC addresses of physical, connected adapters.
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) {
        $lines.Add("MAC Address  : (none)")
    }
    else {
        $first = $true
        foreach ($n in $adapters) {
            $label = if ($first) { "MAC Address  : " } else { "               " }
            $lines.Add("$label$($n.MacAddress)  [$($n.Name)]")
            $first = $false
        }
    }

    # DNS servers, de-duplicated across interfaces, IPv4 first.
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
    if ($dns.Count -eq 0) {
        $lines.Add("DNS Servers  : (none)")
    }
    else {
        $first = $true
        foreach ($d in $dns) {
            $label = if ($first) { "DNS Servers  : " } else { "               " }
            $lines.Add("$label$d")
            $first = $false
        }
    }
    $lines.Add("")

    # Fixed disks: size, free and percentage used.
    #
    # Win32_LogicalDisk, NOT Get-Volume. Get-Volume goes through the Storage
    # WMI provider, which a LIMITED token cannot enumerate - it returns nothing
    # and no error, so the wallpaper rendered "Disks : (none)" on a machine with
    # a perfectly healthy 80GB C:. That is the failure mode this whole script
    # exists to avoid: a confident-looking answer that is simply wrong. The
    # logon task runs limited by design, so the data source has to work there.
    # Win32_LogicalDisk is readable by standard users. DriveType 3 = local disk.
    $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
            Sort-Object DeviceID)
    if ($volumes.Count -eq 0) {
        $lines.Add("Disks        : (none found - check the token this ran under)")
    }
    else {
        $first = $true
        foreach ($v in $volumes) {
            $sizeGB = [math]::Round($v.Size / 1GB, 1)
            $freeGB = [math]::Round($v.FreeSpace / 1GB, 1)
            $usedPct = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100) } else { 0 }
            $label = if ($first) { "Disks        : " } else { "               " }
            $lines.Add(("{0}{1} {2} GB total, {3} GB free ({4}% used)" -f $label, $v.DeviceID, $sizeGB, $freeGB, $usedPct))
            $first = $false
        }
    }

    $lines.Add("")
    $lines.Add("Rendered     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    return $lines
}

function Write-InfoBitmap {
    param(
        # AllowEmptyString is REQUIRED, not decoration. A Mandatory [string[]]
        # rejects an array that contains an empty element with "Cannot bind
        # argument to parameter 'Lines' because it is an empty string" - and
        # the layout below uses "" for the blank separator lines between the
        # host block, the network block and the disk block. Without this the
        # renderer dies on every machine. It did.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $width = 1920
    $height = 1080
    $bmp = New-Object System.Drawing.Bitmap($width, $height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.Clear([System.Drawing.Color]::FromArgb(16, 24, 32))
        $font = New-Object System.Drawing.Font('Consolas', 18, [System.Drawing.FontStyle]::Regular)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 230, 240))
        # Start well clear of the desktop icon column on the left. At x=60 the
        # first characters of every line sat UNDERNEATH the icons and their
        # labels, which is how the first render came out.
        $x = 620.0
        $y = 60.0
        foreach ($line in $Lines) {
            $gfx.DrawString($line, $font, $brush, $x, $y)
            $y += 30.0
        }
        $gfx.Flush()
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Bmp)
    }
    finally {
        if ($gfx) { $gfx.Dispose() }
        if ($bmp) { $bmp.Dispose() }
    }
}

$signature = @"
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
"@

New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
Write-InfoBitmap -Lines (Get-InfoLineList) -Path $OutputPath

if (-not (Test-Path -LiteralPath $OutputPath)) { throw "bitmap was not written to $OutputPath" }
if ((Get-Item -LiteralPath $OutputPath).Length -lt 10240) {
    throw "bitmap at $OutputPath is implausibly small ($((Get-Item -LiteralPath $OutputPath).Length) bytes)"
}

# Centre it, do not stretch: the text is drawn at a fixed size.
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $OutputPath
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '6'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

# SPI_SETDESKWALLPAPER = 0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE = 0x03
$spi = Add-Type -MemberDefinition $signature -Name 'DesktopInfoNative' -Namespace 'Win32' -PassThru
[void]$spi::SystemParametersInfo(0x0014, 0, $OutputPath, 0x03)

Write-Output "desktop info rendered to $OutputPath and applied"
'@

    Set-Content -LiteralPath $renderer -Value $payload -Encoding ASCII -Force
    if (-not (Test-Path -LiteralPath $renderer)) {
        throw "Failed to write the renderer to $renderer"
    }
    Write-Host "Wrote renderer: $renderer"

    # Render once now so a broken renderer fails HERE, loudly, in the build log
    # rather than silently at some future logon on someone else's clone.
    #
    # Deliberately to a THROWAWAY path, then deleted. Do NOT render to the real
    # per-user path during the build: this provisioner runs elevated, so the
    # file would be owned by SYSTEM, and the limited-token logon task could
    # never overwrite it. That would turn a working design into a template that
    # shows the BUILD VM's identity on every clone forever. The render is a
    # proof that the code runs, nothing more - the real bitmap is the logon
    # task's job, on the machine whose details it is describing.
    $proof = Join-Path $env:SystemRoot 'Temp\desktopinfo-buildcheck.bmp'
    Remove-Item -LiteralPath $proof -Force -ErrorAction SilentlyContinue
    Write-Host "Rendering once to $proof to prove the renderer works"
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $renderer -OutputPath $proof

    if (-not (Test-Path -LiteralPath $proof)) {
        throw "The renderer ran but produced no bitmap at $proof"
    }
    $size = (Get-Item -LiteralPath $proof).Length
    if ($size -lt 10240) {
        throw "The rendered bitmap is implausibly small ($size bytes); it would show as a blank wallpaper"
    }
    Write-Host "  verified renderer output: $proof ($([math]::Round($size / 1KB)) KB)"
    Remove-Item -LiteralPath $proof -Force -ErrorAction SilentlyContinue

    # Leave NO bitmap at the shared path. If one is there, a limited user cannot
    # replace it, and the stale copy is what everyone would see.
    if (Test-Path -LiteralPath $bitmap) {
        Write-Host "  removing stale shared-path bitmap: $bitmap"
        Remove-Item -LiteralPath $bitmap -Force
    }

    # AT LOGON, in the logging-on user's context: the wallpaper is a per-user
    # setting, so a SYSTEM task could render the image but not apply it.
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$renderer`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { throw "Scheduled task '$taskName' is not registered after Register-ScheduledTask" }
    if ($task.State -eq 'Disabled') { throw "Scheduled task '$taskName' registered but is Disabled" }
    Write-Host "  verified scheduled task '$taskName' registered (state: $($task.State))"

    Write-Host ""
    Write-Host "Desktop info configured: hostname, IP, MAC, DNS and disks are"
    Write-Host "redrawn at every logon, so clones show their own details."

    exit 0
}
catch {
    Write-Host ""
    Write-Host "80-desktop-info FAILED:"
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
