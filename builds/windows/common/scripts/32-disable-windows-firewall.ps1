###############################################################################
# Name:             32-disable-windows-firewall.ps1
# Description:      Turns the Windows Firewall off for all three profiles
#                   (Domain, Private, Public), then confirms each profile
#                   really reports Enabled=False in BOTH the PersistentStore
#                   (what was written) and the ActiveStore (what is actually
#                   in force).
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and opens a transcript at
#      C:\Install\32-disable-windows-firewall.txt.
#   2. Runs Set-NetFirewallProfile -Profile Domain, Private, Public
#      -Enabled False.
#   3. Re-queries the profiles from each of the two policy stores in turn
#      and prints their Enabled state.
#
# WHAT IT VERIFIES
#   For each of PersistentStore and ActiveStore:
#     - the query returned something at all; an empty result means the
#       firewall state cannot be confirmed and is fatal, not "fine";
#     - all three expected profile names came back. A query that matched
#       fewer profiles than asked for must not pass by having nothing left
#       to check;
#     - every profile's Enabled value is the string 'False'.
#
#   WHY BOTH STORES:
#     PersistentStore is what Set-NetFirewallProfile actually wrote - the
#     local configuration. ActiveStore is the merged, effective state the
#     firewall is really running with. A Group Policy object or a local
#     policy object can hold the firewall ON while the persistent write
#     "succeeds" and reports no error. Checking only PersistentStore would
#     therefore pass on a machine whose firewall is still fully up: exactly
#     the silent no-op this script exists to refuse to report as success.
#
# FAILURE CONTRACT
#   FATAL     : either policy store returning no profiles; any of Domain,
#               Private or Public missing from a store's results; any
#               profile still Enabled=True in either store. All exit 1 and
#               fail the provisioner.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
# NOTES
#   - REAL BUG FIXED HERE: .Enabled is a GpoBoolean enum, not a boolean.
#     False = 2 and True = 1, so [bool]$_.Enabled evaluates to $true for
#     BOTH states and the original cast made this check pass
#     unconditionally. The comparison is done on the string form of the
#     enum value instead. Do not "tidy" it back into a boolean cast.
#   - Disabling the host firewall is only defensible because these
#     templates live on a trusted lab network; a clone exposed further out
#     should have it turned back on.
#   - No reboot is needed for this change: Set-NetFirewallProfile takes
#     effect immediately, which is precisely what the ActiveStore check
#     confirms. (Contrast 31-disable-ipv6.ps1, whose registry half is only
#     staged until the next boot - and note there is NO windows-restart
#     provisioner anywhere in this repo if one is ever required.)
#   - NOT WIRED INTO ANY BUILD. As of this writing no *.pkr.hcl in this
#     repo references 32-disable-windows-firewall.ps1 - not the 2022/2025
#     Core or Desktop Experience ISO builds, and not the cloud-clone build.
#     It is a library script that nothing currently runs, so the shipped
#     templates still have their firewall enabled (see 21-enable-openssh
#     and 22-enable-icmp, which open individual ports rather than relying
#     on this).
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
$logPath = 'C:/Install/32-disable-windows-firewall.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

try {
    Write-Host "Disabling Windows Firewall"

    $expectedProfiles = @('Domain', 'Private', 'Public')

    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False

    # Verify the effect. NOTE: .Enabled is a GpoBoolean enum where
    # False = 2 and True = 1, so [bool]$_.Enabled is $true for BOTH states -
    # the old cast made this check pass unconditionally. Compare the enum
    # value explicitly instead.
    #
    # Both stores are checked on purpose:
    #   PersistentStore - what Set-NetFirewallProfile actually wrote.
    #   ActiveStore     - what the firewall is effectively running with. A GPO
    #                     or a local policy object can hold the firewall ON
    #                     while the persistent write "succeeds", which is
    #                     exactly the silent no-op this script must not report
    #                     as success.
    foreach ($storeName in @('PersistentStore', 'ActiveStore')) {
        $profiles = @(Get-NetFirewallProfile -Profile Domain, Private, Public -PolicyStore $storeName)
        if ($profiles.Count -eq 0) {
            throw "Get-NetFirewallProfile -PolicyStore $storeName returned nothing - cannot verify the firewall state."
        }

        # A query that matched fewer profiles than asked for must not pass by
        # virtue of having nothing left to check.
        $seen = @($profiles | ForEach-Object { [string]$_.Name })
        $missing = @($expectedProfiles | Where-Object { $seen -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw "Firewall profile(s) '$($missing -join ", ")' were not returned by $storeName - cannot confirm they are disabled."
        }

        Write-Host "Firewall status ($storeName):"
        foreach ($fwProfile in $profiles) {
            $state = [string]$fwProfile.Enabled
            Write-Host "  $($fwProfile.Name) profile Enabled=$state"
            if ($state -ne 'False') {
                throw "Windows Firewall profile '$($fwProfile.Name)' is still Enabled=$state in $storeName after Set-NetFirewallProfile."
            }
        }
    }

    Write-Host "Windows Firewall disabled and verified for all profiles (Domain, Private, Public) in both PersistentStore and ActiveStore."

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
