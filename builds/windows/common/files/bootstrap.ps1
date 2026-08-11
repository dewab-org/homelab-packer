###############################################################################
# Name:             bootstrap.ps1
# Description:      Runs at FIRST LOGON from the Autounattend, off the PACKER
#                   ISO. Stages the provisioning scripts, installs the QEMU
#                   guest agent, enables WinRM and PROVES it answers - then
#                   records its verdict in a marker file and always exits 0.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Deletes any packer-bootstrap.failed marker left by a PREVIOUS boot, and
#      says so loudly if it will not go away (a stale marker would report this
#      run as failed).
#   2. Starts the transcript at C:\Windows\Temp\packer-bootstrap.txt - itself
#      isolated, because a transcript that cannot be opened must not take the
#      bootstrap down with it.
#   3. ISOLATED STEP: resolves the media root from $PSScriptRoot, creates
#      C:\Install\scripts and copies scripts\*.ps1 off the ISO.
#   4. ISOLATED STEP: runs 10-install-virtio-guest-tools.ps1 - the FULL guest
#      tools, which install both the agent and the vioser (virtio-serial)
#      driver the agent needs to reach the host.
#   5. ISOLATED STEP: runs 00-install-qemu-ga.ps1 as a fallback. It no-ops when
#      step 4 already registered the service, and is the only path that works
#      if the guest-tools installer is missing from the media. Packer discovers
#      the VM's IP through the agent, so without one of these two WinRM is
#      unreachable even once the listener is up.
#   6. ISOLATED STEP: runs 01-enable-winrm.ps1 - the one step that actually
#      matters for Packer connectivity.
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
#   - WINRM IS PROVEN, NOT ASSUMED: the service must be Running, at least one
#     listener must be registered under WSMan:\localhost\Listener, AND a TCP
#     connect to 127.0.0.1:5985 must succeed. "The step returned" is not
#     evidence - a registered-but-not-answering WinRM is indistinguishable from
#     a working one until Packer's connect timeout expires 90 minutes later.
#   - The failure marker write is itself verified after Out-File; it is the one
#     signal the build reads, so losing it silently would defeat the whole
#     arrangement. If even that cannot be written, the transcript says so in a
#     banner.
#
# FAILURE CONTRACT
#   FATAL     : nothing. This script CANNOT fail the build directly and ALWAYS
#               EXITS 0 - a non-zero exit from a first-logon command aborts the
#               logon sequence and leaves a VM that cannot even be inspected.
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
#   defers the failure by seconds, it does not hide it. Without the reader the
#   convention would be write-only, which is exactly what it used to be.
#
# NOTES
#   - Scope is ONLY what must exist before Packer can connect. Everything else
#     belongs in a provisioner, where a failure is visible and the build can
#     retry.
#   - EVERY step is isolated, not just the numbered scripts. This script used
#     to call four scripts sequentially inside a single try{}, so a throw from
#     an early step silently skipped every later one - including
#     01-enable-winrm. Hardening the individual scripts to fail loudly would
#     have turned a partial failure into "no WinRM listener at all", i.e. a
#     guaranteed 90-minute winrm_timeout with no clue why. The staging work in
#     front of those scripts is isolated for the same reason: a failed
#     Copy-Item must not be able to skip WinRM, since the scripts may already
#     be on disk from an earlier boot.
#   - RDP and OpenSSH are deliberately NOT run here. Both already run as normal
#     provisioners in the builds that ship this file, and 21-enable-openssh
#     calls Add-WindowsCapability, which blocks on Windows Update and has hung
#     first logon indefinitely (see bootstrap-vhd.ps1). First logon is the
#     worst possible place for a call that can block forever, because nothing
#     is watching it yet.
#   - The last-resort enablement is reached only when verification has already
#     failed, so there is nothing left to lose. It is attempted loudly and
#     re-verified - never assumed.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$transcript = "C:\Windows\Temp\packer-bootstrap.txt"
$marker = "C:\Windows\Temp\packer-bootstrap.failed"

# Captured at script scope so the isolated staging step below reads the same
# value regardless of the scope it executes in.
$mediaRoot = $PSScriptRoot

$failures = New-Object System.Collections.Generic.List[string]

# Clear any marker left by a previous boot BEFORE anything else, and notice if
# it will not go away - a stale marker would otherwise report this run as failed.
if (Test-Path -LiteralPath $marker) {
    Remove-Item -Path $marker -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $marker) {
        Write-Host "!!! could not delete the stale failure marker $marker; its contents are from a PREVIOUS boot"
    }
}

# Isolated: a transcript that cannot be opened must not stop the bootstrap. An
# unhandled throw here would abort the script before WinRM is touched at all,
# and leave no marker to explain it.
$transcriptStarted = $false
try {
    Start-Transcript -Path $transcript -Append
    $transcriptStarted = $true
}
catch {
    Write-Host "!!! could not start the transcript at $transcript : $($_.Exception.Message)"
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
    # starts - but a retry budget is not an excuse, it still reports failure.
    [CmdletBinding()]
    param([int]$Attempts = 10, [int]$DelaySeconds = 3)

    $problem = "not checked"

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $svc = Get-Service -Name WinRM -ErrorAction Stop
            if ($svc.Status -ne 'Running') {
                $problem = "WinRM service is $($svc.Status)"
            }
            else {
                $listeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop)
                if ($listeners.Count -eq 0) {
                    $problem = "no WinRM listener is registered"
                }
                else {
                    $client = $null
                    try {
                        $client = New-Object System.Net.Sockets.TcpClient
                        $client.Connect("127.0.0.1", 5985)
                        if ($client.Connected) {
                            Write-Host "    WinRM verified: $($listeners.Count) listener(s), service Running, 127.0.0.1:5985 accepting"
                            return $null
                        }
                        $problem = "nothing is listening on 127.0.0.1:5985"
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
        # This script runs from the PACKER ISO root; use that location directly.
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

    # Packer discovers the VM IP via the guest agent, so without
    # it WinRM is unreachable even once the listener is up. Non-fatal by design
    # (see the script header) -- and isolated, so it cannot skip WinRM below.
    # FULL virtio guest tools first, agent-only MSI second. Both are needed and
    # the order matters:
    #
    # Packer discovers the VM's IP by asking the QEMU guest agent, and the agent
    # talks to the host over a virtio-serial channel. A freshly installed
    # Windows has no virtio-serial (vioser) driver, so the agent-only MSI
    # produces a QEMU-GA service that starts, looks healthy, and cannot reach
    # the host -- `qm agent ping` answers "QEMU guest agent is not running" and
    # Packer waits out its full 90-minute winrm_timeout with no IP.
    #
    # This exact regression was introduced when the per-build bootstraps were
    # consolidated: the old ISO bootstrap installed the full guest tools inline
    # and the replacement called only 00-install-qemu-ga.ps1. bootstrap-vhd.ps1
    # had it right all along; this now matches it.
    #
    # 00-install-qemu-ga.ps1 still runs afterwards as a fallback -- it is a
    # no-op when the guest tools already registered the service, and it is the
    # only path that works if the guest-tools installer is absent from the media.
    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\10-install-virtio-guest-tools.ps1" -Description "install VirtIO guest tools (drivers + agent)"

    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\00-install-qemu-ga.ps1" -Description "install QEMU guest agent"

    # The one step that actually matters for Packer connectivity.
    $null = Invoke-BootstrapScript -Path "C:\Install\scripts\01-enable-winrm.ps1" -Description "enable WinRM"

    # Prove the listener is really there rather than trusting the step above.
    # A broken 01-enable-winrm and a working one look identical from here, and the
    # difference is only discovered 90 minutes later when Packer gives up.
    Write-Host "==> bootstrap: verify WinRM"
    $winrmProblem = Test-WinRmReady

    if ($winrmProblem) {
        # Last resort. Reached only when the verification above already failed,
        # so there is nothing left to lose: if 01-enable-winrm.ps1 was missing
        # or died halfway, a bare quickconfig may still produce a listener and
        # save the build. It is attempted loudly and re-verified - never assumed.
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
            $msg = "verify WinRM : $winrmProblem (last-resort enablement did not help)"
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
}
finally {
    if ($failures.Count -gt 0) {
        Write-Host ""
        Write-Host "*** BOOTSTRAP COMPLETED WITH $($failures.Count) FAILURE(S) ***"
        $failures | ForEach-Object { Write-Host "    - $_" }
        Write-Host "*** Packer will likely fail to connect; see $transcript ***"

        # The marker is the machine-readable verdict, so confirm it landed.
        try {
            $failures -join [Environment]::NewLine |
                Out-File -FilePath $marker -Encoding ascii -Force
            if (-not (Test-Path -LiteralPath $marker)) {
                throw "file does not exist after Out-File"
            }
            Write-Host "*** failure marker written: $marker ***"
        }
        catch {
            Write-Host "*** COULD NOT WRITE THE FAILURE MARKER $marker : $($_.Exception.Message) ***"
            Write-Host "*** the failures listed above are recorded ONLY in this transcript ***"
        }
    }
    else {
        Write-Host "bootstrap completed successfully"
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Host "Stop-Transcript: $($_.Exception.Message)" }
    }
}

# Always exit 0: failing here would fail Windows Setup itself and leave a VM
# that cannot even be inspected. The marker file above carries the verdict.
exit 0
