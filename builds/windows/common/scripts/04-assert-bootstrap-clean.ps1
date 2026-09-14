###############################################################################
# Name:             04-assert-bootstrap-clean.ps1
# Description:      Read the three first-logon bootstrap failure markers and
#                   fail the build if any of them is present, printing the
#                   recorded reason. Runs first among the provisioners.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install if needed and starts a transcript at
#      C:\Install\04-assert-bootstrap-clean.txt (append).
#   2. Tests for three marker files, logging PRESENT/absent for each:
#        C:\Windows\Temp\packer-bootstrap.failed    (bootstrap itself)
#        C:\Windows\Temp\qemu-ga.failed             (guest agent install)
#        C:\Windows\Temp\virtio-guest-tools.failed  (virtio driver install)
#   3. Reads the recorded reason out of each present marker, or notes that the
#      marker is present but unreadable.
#   4. Exits 0 if none are present.
#   5. Otherwise prints a banner with every failure, its marker path, its
#      detail lines and a pointer to C:\Windows\Temp\packer-bootstrap.txt,
#      then throws (or honours the escape hatch below).
#
# WHAT IT VERIFIES
#   - That none of the three markers exists. Presence of one means that
#     bootstrap step reported a failure, and every assumption the later
#     provisioners make about the agent or the drivers is already wrong.
#   - Be clear about the limit: this checks the markers only. It does NOT
#     independently re-test the guest agent, the VirtIO drivers or anything
#     else on the live system - it trusts what the bootstrap scripts wrote.
#     A bootstrap step that fails without writing its marker passes here.
#
# FAILURE CONTRACT
#   FATAL     : one or more markers present and PACKER_IGNORE_BOOTSTRAP_MARKERS
#               unset - throws, then exits 1 and fails the build.
#   LOUD SKIP : PACKER_IGNORE_BOOTSTRAP_MARKERS set downgrades the above to a
#               logged warning and exits 0; acceptable only because it is an
#               explicit opt-in for debugging a knowingly broken bootstrap,
#               and it announces itself in the log every time it is used.
#               Start-Transcript failing is also logged and ignored - the
#               check matters more than its transcript - and a Stop-Transcript
#               failure in the finally is reported rather than swallowed,
#               since an empty catch here would be a silent failure in the one
#               script whose whole job is to make silent failures impossible.
#
# INPUTS (environment)
#   PACKER_IGNORE_BOOTSTRAP_MARKERS
#           Any non-empty value (including "0" - PowerShell treats every
#           non-empty string as true) turns a marker hit into a warning and
#           exits 0. Unset: markers are fatal.
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the VM can
#           be inspected before Packer destroys it. Unset: exit immediately.
#
# NOTES
#   - Why this exists: bootstrap.ps1 and bootstrap-vhd.ps1 run at first logon,
#     before Packer can connect to anything. They MUST NOT fail Windows Setup
#     -- a non-zero exit from the first-logon command aborts the logon
#     sequence and leaves a VM that cannot even be inspected -- so they always
#     exit 0 and record their verdict in a marker file instead.
#   - Nothing in the repo ever read those markers. A bootstrap could skip the
#     guest agent, log a banner, write a marker, and the build would still go
#     green and ship the template: the whole convention was write-only. Worse,
#     some steps legitimately exit 0 after a loud skip, so the bootstrap log
#     itself can read "ok" for a step that did not happen.
#   - This script is the reader, and deliberately the only place those markers
#     are interpreted. It runs FIRST among the provisioners, immediately after
#     WinRM comes up, so a bootstrap problem fails the build in seconds rather
#     than surfacing as something inexplicable an hour later -- or not at all.
###############################################################################

$ErrorActionPreference = "Stop"

$markers = @(
    @{ Path = 'C:\Windows\Temp\packer-bootstrap.failed';   What = 'first-logon bootstrap' },
    @{ Path = 'C:\Windows\Temp\qemu-ga.failed';            What = 'QEMU guest agent install' },
    @{ Path = 'C:\Windows\Temp\virtio-guest-tools.failed'; What = 'VirtIO guest tools install' }
)

try {
    New-Item -Path 'C:\Install' -ItemType Directory -Force | Out-Null
    Start-Transcript -Path 'C:/Install/04-assert-bootstrap-clean.txt' -Append | Out-Null
}
catch {
    Write-Host "could not start transcript: $($_.Exception.Message) - continuing, the check matters more"
}

try {
    Write-Host "Checking for first-logon bootstrap failure markers..."

    $found = @()
    foreach ($marker in $markers) {
        if (Test-Path -LiteralPath $marker.Path) {
            $detail = ''
            try {
                $detail = (Get-Content -LiteralPath $marker.Path -Raw -ErrorAction Stop).Trim()
            }
            catch {
                $detail = "(marker present but unreadable: $($_.Exception.Message))"
            }
            $found += [pscustomobject]@{ What = $marker.What; Path = $marker.Path; Detail = $detail }
            Write-Host "  PRESENT : $($marker.Path)  [$($marker.What)]"
        }
        else {
            Write-Host "  absent  : $($marker.Path)"
        }
    }

    if ($found.Count -eq 0) {
        Write-Host "No bootstrap failure markers present - first-logon bootstrap was clean."
        exit 0
    }

    Write-Host ""
    Write-Host "*******************************************************************"
    Write-Host "*** FIRST-LOGON BOOTSTRAP REPORTED $($found.Count) FAILURE(S)"
    Write-Host "*******************************************************************"
    foreach ($f in $found) {
        Write-Host ""
        Write-Host "  $($f.What)  ($($f.Path))"
        foreach ($line in ($f.Detail -split "`r?`n")) {
            if ($line.Trim()) { Write-Host "      $line" }
        }
    }
    # Dump the bootstrap transcript INTO the Packer log. The marker records
    # that a step failed, not why -- a marker saying "enable WinRM : exited with
    # code 1" tells you nothing about which assertion tripped. The detail lives
    # in the transcript, on a VM that Packer destroys the moment this script
    # fails, so anything not echoed here is gone. That cost a full ~55-minute
    # build to learn once; it should not cost a second one.
    $bootstrapLog = 'C:\Windows\Temp\packer-bootstrap.txt'
    Write-Host ""
    Write-Host "--- $bootstrapLog (last 120 lines) -------------------------------"
    if (Test-Path -LiteralPath $bootstrapLog) {
        try {
            Get-Content -LiteralPath $bootstrapLog -Tail 120 -ErrorAction Stop |
                ForEach-Object { Write-Host "  $_" }
        }
        catch {
            Write-Host "  (could not read it: $($_.Exception.Message))"
        }
    }
    else {
        Write-Host "  (not present - bootstrap may have died before starting its transcript)"
    }

    # Sub-scripts keep their own transcripts; include them for the same reason.
    foreach ($sub in @('C:\Windows\Temp\01-enable-winrm.txt', 'C:\Install\00-install-qemu-ga.txt')) {
        if (Test-Path -LiteralPath $sub) {
            Write-Host ""
            Write-Host "--- $sub (last 60 lines) -----------------------------------"
            try {
                Get-Content -LiteralPath $sub -Tail 60 -ErrorAction Stop |
                    ForEach-Object { Write-Host "  $_" }
            }
            catch {
                Write-Host "  (could not read it: $($_.Exception.Message))"
            }
        }
    }
    Write-Host "*******************************************************************"

    if ($env:PACKER_IGNORE_BOOTSTRAP_MARKERS) {
        Write-Host ""
        Write-Host "PACKER_IGNORE_BOOTSTRAP_MARKERS is set - continuing anyway."
        Write-Host "The template being built is KNOWN to have a broken bootstrap."
        exit 0
    }

    throw "first-logon bootstrap reported $($found.Count) failure(s); see the markers above"
}
catch {
    Write-Host ""
    Write-Host "04-assert-bootstrap-clean FAILED: $($_.Exception.Message)"
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set - holding for 60 minutes for inspection."
        Start-Sleep -Seconds 3600
    }
    exit 1
}
finally {
    # Even this is reported: an empty catch here would be a silent failure in
    # the one script whose entire job is to make silent failures impossible.
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Host "note: Stop-Transcript failed ($($_.Exception.Message)) - transcript may be truncated"
    }
}
