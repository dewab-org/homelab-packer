###############################################################################
# Name:             bootstrap-vhd.ps1
# Description:      Pre-WinRM bootstrap for VHD/VHDX clone builds, run at FIRST
#                   LOGON. Stages the provisioning scripts, installs the virtio
#                   guest tools and the QEMU agent, enables WinRM and PROVES it
#                   answers - then records its verdict and always exits 0.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Deletes any packer-bootstrap.failed marker left by a PREVIOUS boot, and
#      says so loudly if it will not go away.
#   2. Starts the transcript at C:\Windows\Temp\packer-bootstrap.txt - itself
#      isolated, because a transcript that cannot be opened must not take the
#      bootstrap down with it - and closes it in a finally so the exit path
#      cannot leave it open and truncated.
#   3. ISOLATED STEP: resolves the media root from $PSScriptRoot, creates
#      C:\Install\scripts and copies scripts\*.ps1 off the media.
#   4. ISOLATED STEP: runs 10-install-virtio-guest-tools.ps1 - the FULL guest
#      tools bundle, not just the agent MSI (see NOTES).
#   5. ISOLATED STEP: runs 00-install-qemu-ga.ps1 as a fallback, isolated from
#      the step above precisely so a guest-tools failure cannot skip the
#      fallback that exists to cover it.
#   6. ISOLATED STEP: runs 01-enable-winrm.ps1.
#   7. Verifies WinRM for real: up to 10 attempts, 3s apart.
#   8. If that fails, a last-resort inline `winrm quickconfig -quiet` plus
#      Set-Service Automatic / Start-Service, then re-verifies (5 attempts).
#   9. On any failure: prints a banner, writes every failure into
#      C:\Windows\Temp\packer-bootstrap.failed, and exits 0 regardless.
#
# WHAT IT VERIFIES
#   - At least one .ps1 is present in C:\Install\scripts after the copy.
#   - Each sub-script is judged by BOTH a thrown exception AND a non-zero exit
#     code, with $LASTEXITCODE reset to 0 first so a script that returns
#     without calling exit is not judged by some earlier command's stale value.
#   - THE ONE GUARANTEE THIS SCRIPT EXISTS TO PROVIDE - a WinRM listener that
#     actually answers - is checked here rather than delegated to
#     01-enable-winrm.ps1 and hoped for: the service must be Running, a
#     listener must be registered under WSMan:\localhost\Listener, AND a TCP
#     connect to 127.0.0.1:5985 must succeed. An unverified bootstrap turns
#     into a silent 90-minute WinRM timeout with nothing in the log.
#   - The failure marker write is verified after Out-File; if even that cannot
#     be written, the transcript says so in a banner.
#
# FAILURE CONTRACT
#   FATAL     : nothing. This script CANNOT fail the build directly and ALWAYS
#               EXITS 0 - it runs from the first-logon command, and a non-zero
#               exit there aborts the logon sequence rather than producing
#               anything useful.
#   LOUD SKIP : every step failure. Each step runs in its own try/catch,
#               records the failure and returns, so a broken step cannot skip
#               the steps after it - most importantly cannot skip WinRM.
#
#   WHY EXIT 0 IS NOT A SILENT FAILURE HERE: the verdict is written to
#   C:\Windows\Temp\packer-bootstrap.failed (alongside qemu-ga.failed and
#   virtio-guest-tools.failed from the sub-scripts), and
#   scripts/04-assert-bootstrap-clean.ps1 runs as the FIRST provisioner, the
#   moment WinRM comes up, reads those markers, prints their contents and fails
#   the build. The marker plus that assert script close the loop: exiting 0
#   defers the failure by seconds, it does not hide it.
#
# NOTES
#   - FULL GUEST TOOLS, NOT JUST THE AGENT MSI. The agent reaches the host over
#     a virtio-serial channel, and a vendor image has no virtio-serial driver,
#     so `qm agent ping` keeps reporting "not running" even while the service
#     is Running inside the guest - observed exactly that. The guest-tools
#     installer supplies vioser (and viostor/vioscsi/netkvm, which the
#     post-build bus switch needs) along with the agent. The agent matters
#     because the Proxmox builder discovers the VM's IP by querying it;
#     without it Packer waits on WinRM forever while the guest sits happily on
#     a DHCP lease.
#   - Everything else (RDP, OpenSSH, Ansible remoting, ...) runs as a normal
#     provisioner once Packer is connected. That is not tidiness: the shared
#     ISO bootstrap also runs 21-enable-openssh, and Add-WindowsCapability
#     blocks on Windows Update, which on this image hung the whole bootstrap
#     indefinitely. Anything that can wait until after the connection should.
#   - EVERY step is isolated. This script used to run the guest-tools install,
#     the agent MSI fallback and 01-enable-winrm as bare sequential calls
#     inside one try{}, so a throw in the FIRST skipped the other two -
#     including WinRM, and including the fallback for that very failure.
#   - The last-resort enablement is reached only when verification has already
#     failed, so there is nothing left to lose. It is attempted loudly and
#     re-verified - never assumed.
###############################################################################
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$transcriptPath = "C:\Windows\Temp\packer-bootstrap.txt"
$failedMarker = "C:\Windows\Temp\packer-bootstrap.failed"

# Captured at script scope so the isolated staging step reads the same value
# regardless of the scope it executes in.
$mediaRoot = $PSScriptRoot

$failures = New-Object System.Collections.Generic.List[string]

# Clear a marker left by a previous boot before anything else, and say so if it
# will not go away - a stale marker would report this run as failed.
if (Test-Path -LiteralPath $failedMarker) {
    Remove-Item -LiteralPath $failedMarker -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $failedMarker) {
        Write-Host "!!! could not delete the stale failure marker $failedMarker; its contents are from a PREVIOUS boot"
    }
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath -Append
    $transcriptStarted = $true
}
catch {
    Write-Host "!!! could not start the transcript at $transcriptPath : $($_.Exception.Message)"
    Write-Host "!!! continuing without one - WinRM matters more than the log"
}

function Invoke-BootstrapStep {
    # Run one unit of bootstrap work in isolation. Records the failure and
    # returns instead of throwing, so a broken step cannot skip the steps after
    # it. Returns $true on success.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host "==> bootstrap: $Description"
    try {
        & $Action
        Write-Host "    $Description : ok"
        return $true
    }
    catch {
        $msg = "$Description : $($_.Exception.Message)"
        Write-Host "!!! $msg"
        $script:failures.Add($msg)
        return $false
    }
}

function Invoke-BootstrapScript {
    # Run one bootstrap .ps1 in isolation, judged by both a thrown exception and
    # a non-zero exit code. Returns $true on success.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Write-Host "==> bootstrap: $Description"
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "script not found at $Path"
        }
        # Reset first: $LASTEXITCODE persists across commands, so a script that
        # returns without calling exit would otherwise be judged by whatever
        # stale value some earlier native command left behind.
        $global:LASTEXITCODE = 0
        & $Path
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "exited with code $LASTEXITCODE"
        }
        Write-Host "    $Description : ok"
        return $true
    }
    catch {
        $msg = "$Description : $($_.Exception.Message)"
        Write-Host "!!! $msg"
        $script:failures.Add($msg)
        return $false
    }
}

function Test-WinRmReady {
    # The only question that matters: can something connect to 5985 right now?
    # Returns $null when ready, or a string describing the first thing found
    # wrong. Retries, because the listener can need a moment after the service
    # starts - but the budget is not an excuse, it still reports failure.
    [CmdletBinding()]
    param([int]$Attempts = 10, [int]$DelaySeconds = 3)

    $problem = "not checked"

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $svc = Get-Service -Name WinRM -ErrorAction Stop
            if ($svc.Status -ne 'Running') {
                $problem = "the WinRM service is '$($svc.Status)', not Running"
            }
            else {
                $listeners = @(Get-ChildItem -Path "WSMan:\localhost\Listener" -ErrorAction Stop)
                if ($listeners.Count -eq 0) {
                    $problem = "no listener registered under WSMan:\localhost\Listener"
                }
                else {
                    $client = $null
                    try {
                        $client = New-Object System.Net.Sockets.TcpClient
                        $client.Connect("127.0.0.1", 5985)
                        if ($client.Connected) {
                            Write-Host "    WinRM verified: service Running, $($listeners.Count) listener(s), 127.0.0.1:5985 accepting connections."
                            return $null
                        }
                        $problem = "nothing answered on 127.0.0.1:5985"
                    }
                    finally {
                        if ($client) { $client.Dispose() }
                    }
                }
            }
        }
        catch {
            $problem = $_.Exception.Message
        }

        Write-Host "    WinRM check attempt $attempt/$Attempts : $problem"
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $problem
}

try {
    # --- stage the scripts (isolated; must not be able to skip WinRM) --------
    $null = Invoke-BootstrapStep -Description "stage provisioning scripts from the PACKER media" -Action {
        if (-not $mediaRoot -or -not (Test-Path $mediaRoot)) {
            throw "unable to determine PACKER media root (PSScriptRoot='$mediaRoot')"
        }
        New-Item -Path "C:\Install" -ItemType Directory -Force | Out-Null
        New-Item -Path "C:\Install\scripts" -ItemType Directory -Force | Out-Null
        if (-not (Test-Path "C:\Install\scripts")) {
            throw "C:\Install\scripts does not exist after New-Item"
        }

        Copy-Item -Path (Join-Path $mediaRoot "scripts\*.ps1") -Destination "C:\Install\scripts" -Force

        $copied = @(Get-ChildItem -Path "C:\Install\scripts" -Filter "*.ps1" -ErrorAction SilentlyContinue)
        if ($copied.Count -eq 0) {
            throw "no .ps1 files present in C:\Install\scripts after the copy"
        }
        Write-Host "    staged $($copied.Count) script(s) into C:\Install\scripts"
    }

    # Full virtio guest tools, not just the agent MSI. Installing qemu-ga alone
    # is not enough: the agent reaches the host over a virtio-serial channel,
    # and a vendor image has no virtio-serial driver, so `qm agent ping` keeps
    # reporting "not running" even while the service is Running inside the
    # guest - observed exactly that. The guest-tools installer supplies
    # vioser (and viostor/vioscsi/netkvm, which the post-build bus switch needs)
    # along with the agent.
    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\10-install-virtio-guest-tools.ps1" -Description "install virtio guest tools"

    # Fallback: if the bundle did not register the agent for any reason, the
    # agent-only MSI is cheap to retry and is a no-op when already present. It
    # is isolated from the step above precisely so a guest-tools failure cannot
    # skip the fallback for that failure.
    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\00-install-qemu-ga.ps1" -Description "install QEMU guest agent (fallback)"

    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\01-enable-winrm.ps1" -Description "enable WinRM"

    # ------------------------------------------------------------------
    # Verify the effect. 01-enable-winrm.ps1 returning is not evidence that
    # Packer can connect; a registered-but-not-listening WinRM is exactly the
    # failure mode that costs a full connect timeout to discover.
    # ------------------------------------------------------------------
    Write-Host "==> bootstrap: verify WinRM"
    $winrmProblem = Test-WinRmReady

    if ($winrmProblem) {
        # Last resort, reached only when the verification already failed, so
        # there is nothing left to lose: if 01-enable-winrm.ps1 was missing or
        # died halfway, a bare quickconfig may still produce a listener and save
        # the build. Attempted loudly and re-verified - never assumed.
        Write-Host "!!! WinRM is not answering ($winrmProblem)"
        Write-Host "!!! attempting a last-resort inline WinRM enablement"

        $null = Invoke-BootstrapStep -Description "last-resort WinRM enablement" -Action {
            $global:LASTEXITCODE = 0
            & winrm.exe quickconfig -quiet
            $quickconfigExit = $LASTEXITCODE
            Write-Host "    winrm quickconfig exit code: $quickconfigExit"

            Set-Service -Name WinRM -StartupType Automatic
            Start-Service -Name WinRM

            if ($quickconfigExit -ne 0) {
                throw "winrm quickconfig exited $quickconfigExit"
            }
        }

        $winrmProblem = Test-WinRmReady -Attempts 5
        if ($winrmProblem) {
            $msg = "verify WinRM : $winrmProblem (last-resort enablement did not help). Packer would sit in a WinRM timeout with no other clue."
            Write-Host "!!! $msg"
            $failures.Add($msg)
        }
        else {
            Write-Host "    WinRM recovered by the last-resort enablement"
        }
    }
}
catch {
    # Nothing above should reach here - every step is isolated - but an escape
    # must still be recorded rather than lost.
    $failures.Add("bootstrap: $($_.Exception.Message)")
    Write-Host $_.ScriptStackTrace
}
finally {
    if ($failures.Count -gt 0) {
        Write-Host "##############################################################"
        Write-Host "# BOOTSTRAP FAILED - Packer may not be able to connect.      #"
        Write-Host "##############################################################"
        Write-Host "$($failures.Count) failure(s):"
        $failures | ForEach-Object { Write-Host "    - $_" }

        try {
            $failures -join [Environment]::NewLine |
                Out-File -FilePath $failedMarker -Encoding ascii -Force
            if (-not (Test-Path -LiteralPath $failedMarker)) {
                throw "file does not exist after Out-File"
            }
            Write-Host "failure marker written: $failedMarker"
        }
        catch {
            Write-Host "### COULD NOT WRITE THE FAILURE MARKER $failedMarker : $($_.Exception.Message) ###"
            Write-Host "### the failures listed above are recorded ONLY in this transcript ###"
        }
    }
    else {
        Write-Host "bootstrap completed successfully"
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Host "Stop-Transcript: $($_.Exception.Message)" }
    }
}

# Exit 0 is deliberate (see header): a non-zero exit from the first-logon
# command aborts the logon sequence. The marker file above is the signal.
exit 0
