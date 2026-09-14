###############################################################################
# Name:             70-windows-subsys-linux-part1.ps1
# Description:      Part 1 of the WSL setup: enables the VirtualMachinePlatform
#                   and Microsoft-Windows-Subsystem-Linux optional features
#                   without restarting, and asserts both reach Enabled or
#                   EnablePending. No reboot and no distro install happen here.
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and starts a transcript at
#      C:\Install\70-windows-subsys-linux-part1.txt.
#   2. For each of VirtualMachinePlatform and
#      Microsoft-Windows-Subsystem-Linux: reads the current state with
#      Get-WindowsOptionalFeature and skips the feature when it is already
#      Enabled.
#   3. Otherwise runs Enable-WindowsOptionalFeature -Online -NoRestart and
#      keeps the returned RestartNeeded flag instead of discarding it.
#   4. Re-reads the state immediately, then re-asserts both features in a
#      final loop.
#   5. Logs that a restart is required when any feature asked for one.
#
# WHAT IT VERIFIES
#   - After enabling, the feature state read back from the live system is
#     Enabled or EnablePending. The cmdlet returning without error is not
#     proof that the feature actually changed state.
#   - A final loop re-reads BOTH features regardless of which branch ran, so
#     the "already Enabled" path is asserted too.
#
# FAILURE CONTRACT
#   FATAL     : a feature is in any state other than Enabled/EnablePending
#               right after being enabled; the final verification finds
#               either feature in another state; Get-WindowsOptionalFeature or
#               Enable-WindowsOptionalFeature throws - for example when the
#               feature name is not present on the running SKU.
#   LOUD SKIP : none. A feature that is already Enabled is logged and skipped,
#               which is the idempotent path, not a skipped install.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   when set, sleeps 3600s on failure so the transcript
#                       can be read before Packer destroys the VM. Unset by
#                       default.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. Neither this script nor its part-2 counterpart
#     is referenced by any *.pkr.hcl; both are library scripts.
#   - ORDERING: the features are enabled with -NoRestart, so WSL is not usable
#     when this script ends. 71-windows-subsys-linux-part2.ps1 installs the
#     distro and must run AFTER a reboot. This repo has no windows-restart
#     provisioner anywhere, so a caller wiring these in must add one between
#     part 1 and part 2, otherwise part 2 runs against features that are only
#     EnablePending.
#   - The transcript name tracks the script number; it was renamed from
#     57-windows-subsys-linux.txt when the library was renumbered by
#     execution phase.
###############################################################################

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$features = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/70-windows-subsys-linux-part1.txt' -Append

try {
    Write-Host "Configuring WSL"
    $restartNeeded = $false

    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -eq 'Enabled') {
            Write-Host "$feature is already Enabled"
            continue
        }

        Write-Host "Enabling $feature (currently $state)"
        # The return value carries RestartNeeded and must not be discarded.
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        if ($result.RestartNeeded) {
            $restartNeeded = $true
        }

        # Verify the effect: the cmdlet returning is not proof the feature
        # actually changed state.
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -ne 'Enabled' -and $state -ne 'EnablePending') {
            throw "Enable-WindowsOptionalFeature returned without error but $feature is in state '$state' (expected Enabled or EnablePending)."
        }

        Write-Host "$feature is now $state"
    }

    # Final assertion over both features, independent of which branch ran.
    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -ne 'Enabled' -and $state -ne 'EnablePending') {
            throw "Verification failed: $feature is in state '$state'."
        }
        Write-Host "Verified: $feature = $state"
    }

    if ($restartNeeded) {
        Write-Host "A restart is required before WSL is usable; part 2 handles the distro install after the reboot."
    }

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
