###############################################################################
# Name:             55-install-non-choco-software.ps1
# Description:      Downloads installers that are not available through
#                   Chocolatey from an internal file share, runs them silently,
#                   checks every exit code and proves every install by the
#                   files it left on disk. One entry is active today:
#                   SecureCRT/SecureFX.
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\55-install-non-choco-software.txt.
#   2. Requires PACKER_FILES_BASEURL and strips any trailing '/' from it.
#   3. Validates the whole $installers table before touching the machine:
#      description, relativePath, path and args must all be non-empty, and
#      the 'verify' list must not be empty.
#   4. Forces TLS 1.2, then for each installer: removes any stale local copy,
#      downloads <baseUrl>/<relativePath> with a 600s timeout, validates the
#      download, runs it via Start-Process -Wait -PassThru with its silent
#      arguments, and confirms the files it should have created.
#
# WHAT IT VERIFIES
#   - Download: the file exists, is at least 1MB, and - for a .exe - starts
#     with the 'MZ' executable header. A share answering with an HTML error
#     page is caught here instead of being executed.
#   - Checksum: enforced when the entry pins a sha256. When the pin is empty,
#     as it currently is for SecureCRT/SecureFX, a WARNING states that only
#     size and header were checked.
#   - Exit code: Start-Process is called with -PassThru precisely because
#     without it the exit code is discarded and a silently failing installer
#     looks like success. Accepted: 0 and 3010 (MSI reboot-required).
#   - That the install landed: every path in the entry's 'verify' list must
#     exist, polled once a second for up to 30 seconds because some
#     installers return before their last file is written. For
#     SecureCRT/SecureFX that path is
#     C:\Program Files\VanDyke Software\Clients\SecureCRT.exe. An entry with
#     an empty verify list is refused outright rather than reported as
#     verified.
#
# FAILURE CONTRACT
#   FATAL     : PACKER_FILES_BASEURL unset or blank; any malformed installer
#               entry or empty verify list; a download that is missing, under
#               1MB, not 'MZ', or checksum-mismatched; an installer exit code
#               outside {0,3010}; a verify path that never appears within the
#               30s poll.
#   LOUD SKIP : the $installers table is empty - logs "SKIPPED: no
#               non-Chocolatey installers configured" and exits 0. It is not
#               currently empty: TextExpander is commented out but
#               SecureCRT/SecureFX remains active.
#
# INPUTS (environment)
#   PACKER_FILES_BASEURL   base URL of the internal installer share, of the
#                          form https://<host>/api/public/dl/<token>/
#                          packer_build_files - the token is in the path.
#                          No default - unset or blank is fatal.
#   PACKER_DEBUG_HOLD      when set, sleeps 3600s on failure so the transcript
#                          can be read before Packer destroys the VM. Unset by
#                          default.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. No *.pkr.hcl in this repo references this
#     script, and nothing here sets PACKER_FILES_BASEURL; it is a library
#     script.
#   - CREDENTIALS: the share URL embeds a private access token, which is why
#     it is deliberately NOT stored in git and comes from the environment
#     instead - set it via environment_vars on the Packer provisioner. No
#     credential or token lives anywhere in this repo. Only the relative file
#     name is logged; the base URL never is.
###############################################################################

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

###############################################################################
# Software Details
###############################################################################
# relativePath is appended to $env:PACKER_FILES_BASEURL.
# sha256 is optional: when set it is enforced, when empty the download is only
# sanity-checked (size + executable header).
# verify lists paths that MUST exist after the installer runs.
$installers = @(
    @{
        description  = 'SecureCRT/SecureFX'
        relativePath = 'windows/scrt-sfx-x64-bsafe.9.5.0.3241.exe'
        path         = 'C:\Install\scrt-sfx.exe'
        args         = '/s /v"/qn"'
        sha256       = ''
        verify       = @('C:\Program Files\VanDyke Software\Clients\SecureCRT.exe')
    }
    #    @{
    #        description  = "TextExpander";
    #        relativePath = "windows/TextExpanderSetup-7.0.1.exe";
    #        path         = "C:\Install\textexpander.exe";
    #        args         = '/install /q';
    #        sha256       = '';
    #        verify       = @('C:\Program Files\TextExpander\TextExpander.exe')
    #    }
)

# MSI-based installers return 3010 when they succeeded but want a reboot.
$acceptableExitCodes = @(0, 3010)
$minimumInstallerBytes = 1MB

###############################################################################
# Functions
###############################################################################

function Get-FileHeaderAscii {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Count = 2
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $Count)
        return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    }
    finally {
        $stream.Dispose()
    }
}

function Confirm-Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Download of $Description reported success but $Path does not exist."
    }

    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt $minimumInstallerBytes) {
        throw "Download of $Description is only $size bytes (expected at least $minimumInstallerBytes). This is almost certainly an HTML error page from the file share, not an installer - refusing to execute it."
    }

    if ([System.IO.Path]::GetExtension($Path) -eq '.exe') {
        $magic = Get-FileHeaderAscii -Path $Path
        if ($magic -ne 'MZ') {
            throw "Download of $Description does not start with the 'MZ' executable header (got '$magic'); refusing to execute it."
        }
    }

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpper()) {
            throw "Checksum mismatch for ${Description}: expected $($Sha256.ToUpper()), got $actual."
        }
        Write-Host "Checksum verified for $Description"
    }
    else {
        Write-Host "WARNING: no sha256 pinned for $Description; only size and header were checked."
    }

    Write-Host "Downloaded $Description ($size bytes)"
}

function Confirm-Installed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Paths
    )

    # An empty verify list would make this function a no-op that still lets the
    # caller print "installed and verified". Refuse to be that function.
    if ($Paths.Count -eq 0) {
        throw "No verification paths were defined for $Description, so the install cannot be proven. Add at least one path to its 'verify' entry."
    }

    foreach ($expected in $Paths) {
        $found = $false
        # Some installers return before the last file is written.
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            if (Test-Path -LiteralPath $expected) {
                $found = $true
                break
            }
            Start-Sleep -Seconds 1
        }

        if (-not $found) {
            throw "$Description reported a successful exit code but $expected does not exist. The installer did nothing."
        }

        Write-Host "Verified $Description installed: $expected"
    }
}

###############################################################################
# Main
###############################################################################

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/55-install-non-choco-software.txt' -Append

try {
    if ($installers.Count -eq 0) {
        Write-Host "SKIPPED: no non-Chocolatey installers configured, so nothing was installed."
        exit 0
    }

    $baseUrl = $env:PACKER_FILES_BASEURL
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        throw "PACKER_FILES_BASEURL is not set. The installer share URL carries a private token and is not stored in git, so this script cannot download anything. Set PACKER_FILES_BASEURL in the Packer provisioner environment_vars (see the header of this script)."
    }
    $baseUrl = $baseUrl.TrimEnd('/')

    ###########################################################################
    # Validate the table before touching the machine
    ###########################################################################
    # A malformed entry must fail here rather than silently install nothing or
    # install something that is never verified.
    foreach ($item in $installers) {
        foreach ($key in @('description', 'relativePath', 'path', 'args')) {
            if ([string]::IsNullOrWhiteSpace([string]$item[$key])) {
                throw "Installer definition is missing a value for '$key': $($item | Out-String)"
            }
        }
        if (@($item.verify).Count -eq 0) {
            throw "Installer definition for $($item.description) has an empty 'verify' list; an install that cannot be proven is not allowed."
        }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($item in $installers) {
        # Deliberately log the file name only - the base URL embeds a token.
        Write-Host "Download $($item.description) [$($item.relativePath)]"
        $url = '{0}/{1}' -f $baseUrl, $item.relativePath.TrimStart('/')

        if (Test-Path -LiteralPath $item.path) {
            Remove-Item -LiteralPath $item.path -Force
        }

        # Limited egress: a download must time out rather than hang the build.
        Invoke-WebRequest -Uri $url -OutFile $item.path -UseBasicParsing -TimeoutSec 600

        Confirm-Download -Path $item.path -Description $item.description -Sha256 $item.sha256

        Write-Host "Install $($item.description)"
        # -PassThru is mandatory: without it Start-Process discards the exit
        # code and a silently failing installer looks like success.
        $process = Start-Process -FilePath $item.path -ArgumentList $item.args -Wait -PassThru
        if ($acceptableExitCodes -notcontains $process.ExitCode) {
            throw "$($item.description) installer exited with code $($process.ExitCode)."
        }

        Confirm-Installed -Description $item.description -Paths $item.verify
    }

    Write-Host "All $($installers.Count) non-Chocolatey installers completed and verified."
    exit 0
}
catch {
    Write-Host "Something went wrong: $($_.Exception.Message)"

    # Optional debug hold: set PACKER_DEBUG_HOLD=1 to keep the VM alive for an
    # hour so the error can be inspected before Packer destroys it.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600 seconds before failing."
        Start-Sleep -Seconds 3600
    }

    exit 1
}
finally {
    Stop-Transcript
}
