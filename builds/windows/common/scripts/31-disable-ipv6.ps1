###############################################################################
# Name:             31-disable-ipv6.ps1
# Description:      Disables IPv6 two ways: sets the Tcpip6 registry value
#                   DisabledComponents to 0xFF (all components off at next
#                   boot) and unbinds the ms_tcpip6 protocol from every
#                   network adapter (effective immediately). Both halves are
#                   read back from the live system before success.
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and opens a transcript at
#      C:\Install\31-disable-ipv6.txt.
#   2. Creates HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters if
#      absent, then sets DisabledComponents (DWORD) = 0xFF.
#   3. Enumerates all adapters with Get-NetAdapter and runs
#      Disable-NetAdapterBinding -ComponentID ms_tcpip6 on each one.
#   4. Prints a loud REBOOT REQUIRED banner - see FAILURE CONTRACT / NOTES.
#
# WHAT IT VERIFIES
#   - DisabledComponents reads back as 0xFF from the registry. A mismatch
#     means the write did not land where it was aimed.
#   - Get-NetAdapter returned at least one adapter. Zero adapters would let
#     the per-adapter loop pass vacuously, so it is treated as fatal rather
#     than as "nothing to do".
#   - For every adapter, the ms_tcpip6 binding is readable AND every
#     returned binding has Enabled = $false. The result is forced into an
#     array first, because a non-empty array is truthy regardless of the
#     Enabled values inside it - a plain truthiness check here would pass on
#     an adapter that still has IPv6 bound.
#
# FAILURE CONTRACT
#   FATAL     : DisabledComponents not 0xFF on read-back; Get-NetAdapter
#               returning no adapters; the ms_tcpip6 binding unreadable for
#               an adapter; ms_tcpip6 still Enabled on any adapter. All
#               exit 1 and fail the provisioner.
#
#   REBOOT REQUIRED - and this script CANNOT satisfy it. The adapter
#   unbinding is live the moment it runs, but DisabledComponents=0xFF does
#   nothing until the next boot. The script therefore exits 0 with a banner
#   saying the change is only PARTLY live, rather than pretending the job
#   is finished. There is NO windows-restart provisioner anywhere in this
#   repo, so nothing will reboot the VM for you: if a build depends on IPv6
#   actually being off, the caller MUST add a reboot after this script.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
# NOTES
#   - NOT WIRED INTO ANY BUILD. As of this writing no *.pkr.hcl in this
#     repo references 31-disable-ipv6.ps1 - not the 2022/2025 Core or
#     Desktop Experience ISO builds, and not the cloud-clone build.
#     It is a library script that nothing currently runs. Do not assume the
#     shipped templates have IPv6 disabled because this file exists.
#   - The transcript uses -Force in addition to -Append, so a transcript
#     left open by an earlier crashed run does not block logging.
#   - The explicit 'exit 0' is load-bearing. Packer's default powershell
#     execute_command ends with 'exit $LastExitCode', which would otherwise
#     propagate whatever a stale native command left behind.
###############################################################################

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# Start-Transcript throws if the directory is missing. Do not rely on an
# earlier provisioner having created C:\Install.
New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null

# Start transcript to log actions
$logPath = 'C:/Install/31-disable-ipv6.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

try {
    Write-Host "Disabling IPv6"

    # -----------------------------------------------------------------
    # Registry: disable all IPv6 components.
    # -----------------------------------------------------------------
    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
    $valueName = 'DisabledComponents'
    $expectedValue = 0xFF

    if (-not (Test-Path -LiteralPath $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    Set-ItemProperty -Path $registryPath -Name $valueName -Value $expectedValue -Type DWord

    # Verify the effect: read the value back out of the registry.
    $liveValue = (Get-ItemProperty -Path $registryPath -Name $valueName).$valueName
    if ($liveValue -ne $expectedValue) {
        throw ("$registryPath\$valueName is 0x{0:X} after being set, expected 0x{1:X}." -f $liveValue, $expectedValue)
    }
    Write-Host ("Verified $valueName = 0x{0:X} in $registryPath" -f $liveValue)

    # -----------------------------------------------------------------
    # Per-adapter: unbind ms_tcpip6.
    # -----------------------------------------------------------------
    $adapters = @(Get-NetAdapter)
    if ($adapters.Count -eq 0) {
        throw "Get-NetAdapter returned no adapters - refusing to report success."
    }

    foreach ($adapter in $adapters) {
        Write-Host "Disabling ms_tcpip6 on adapter: $($adapter.Name)"
        Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6
    }

    # Verify the effect: read every binding back. Force an array so that a
    # multi-result query cannot pass the check vacuously - a non-empty array
    # is truthy regardless of the Enabled values inside it.
    foreach ($adapter in $adapters) {
        $bindings = @(Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)
        if ($bindings.Count -eq 0) {
            throw "Could not read the ms_tcpip6 binding for adapter '$($adapter.Name)'."
        }
        foreach ($binding in $bindings) {
            if ($binding.Enabled -ne $false) {
                throw "ms_tcpip6 is still enabled on adapter '$($adapter.Name)' (Enabled=$([string]$binding.Enabled))."
            }
        }
        Write-Host "Verified ms_tcpip6 disabled on adapter: $($adapter.Name)"
    }

    Write-Host "IPv6 disabled and verified on $($adapters.Count) adapter(s)"

    # The registry half of this change is STAGED, not live. Say so unmistakably
    # rather than letting the line above read as a completed job.
    Write-Host "***************************************************************"
    Write-Host "*** WARNING: REBOOT REQUIRED - CHANGE IS ONLY PARTLY LIVE   ***"
    Write-Host "*** ms_tcpip6 is unbound now, but DisabledComponents=0xFF   ***"
    Write-Host "*** does not take effect until the next boot.               ***"
    Write-Host "*** There is no windows-restart provisioner in this repo -  ***"
    Write-Host "*** the caller MUST add one after this script if the build  ***"
    Write-Host "*** depends on IPv6 actually being off.                     ***"
    Write-Host "***************************************************************"

    # Explicit success code. Packer's default powershell execute_command ends
    # with 'exit $LastExitCode', which would otherwise propagate whatever a
    # stale native command left behind.
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
