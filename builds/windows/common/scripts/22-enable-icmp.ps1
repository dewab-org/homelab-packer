###############################################################################
# Name:             22-enable-icmp.ps1
# Description:      Allows inbound ping through the Windows Firewall by
#                   creating two stable, idempotent rules - ICMPv4 Echo
#                   Request (type 8) and ICMPv6 Echo Request (type 128) -
#                   removing the auto-named duplicates older revisions left
#                   behind, then reading every rule back off the live
#                   firewall before reporting success.
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################
#
# WHAT IT DOES
#   1. Opens a transcript at C:\Install\22-enable-icmp.txt.
#   2. Defines two rules with fixed -Name values:
#        Homelab-Allow-ICMPv4-Echo-In   ICMPv4, IcmpType 8
#        Homelab-Allow-ICMPv6-Echo-In   ICMPv6, IcmpType 128
#   3. Deletes any leftover rules whose DisplayName is 'Allow inbound ICMPv4'
#      or 'Allow inbound ICMPv6' and whose -Name is not one of the two above
#      (the auto-named duplicates from older revisions of this script).
#   4. Creates each rule, or updates it in place when a rule with that -Name
#      already exists: Inbound, Allow, Profile Any, Enabled True.
#
# WHAT IT VERIFIES
#   - The legacy duplicates are actually gone after removal, re-queried by
#     DisplayName. Remove-NetFirewallRule throwing on error is not treated
#     as proof that the rules left.
#   - For each of the two rules, read back from the live firewall:
#       * the rule exists at all - absence means the write silently no-oped;
#       * Enabled=True - a present but disabled rule blocks nothing in;
#       * Direction=Inbound and Action=Allow;
#       * DisplayName matches, because -NewDisplayName/-DisplayName is a
#         write like any other and can fail like any other;
#       * the port filter's Protocol is ICMPv4 / ICMPv6 as intended;
#       * the port filter's IcmpType is 8 / 128 respectively. This is the
#         assertion that would have caught the type-8-on-IPv6 bug below.
#
# FAILURE CONTRACT
#   FATAL     : a legacy duplicate survives removal; a rule is missing after
#               configuration; a rule is disabled, outbound, not Allow, has
#               the wrong DisplayName, the wrong protocol, or the wrong ICMP
#               type. All exit 1 and fail the provisioner.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block logs and then
#                       sleeps 3600s before exiting 1, so the error stays
#                       readable before Packer destroys the VM. Unset: exit
#                       immediately.
#
# NOTES
#   - REAL BUG FIXED HERE: ICMPv4 Echo Request is type 8, but ICMPv6 Echo
#     Request is type 128. Type 8 is an IPv4-only code point, so the old
#     '-Protocol ICMPv6 -IcmpType 8' rule was syntactically valid, created
#     cleanly, showed as Enabled - and matched no packet whatsoever. IPv6
#     ping stayed broken while the firewall looked correctly configured.
#     Do not "simplify" the two rules back into one shared IcmpType.
#   - The other historical defect: earlier revisions created rules with
#     -DisplayName only, so Windows auto-generated a fresh -Name on every
#     run and each build piled up another duplicate. Both rules now carry
#     an explicit -Name, which is what makes this script idempotent; step 3
#     exists purely to clean up images built before that fix.
#   - This script does NOT create C:\Install before Start-Transcript, unlike
#     its siblings. It relies on an earlier provisioner (20/21) having made
#     the directory. It is always sequenced after them in every build, but
#     running it standalone on a clean image will fail at the transcript.
#   - The explicit 'exit 0' lives INSIDE the try on purpose. Packer runs
#     this as '... ; exit $LastExitCode', so falling off the end would hand
#     the verdict to a stale exit code; putting it after the try/catch would
#     mask a caught failure. 'exit' still runs the finally, so the
#     transcript is closed either way.
#   - Wired into every Windows build: the 2022 and 2025 Core and Desktop
#     Experience ISO builds, and common/cloud-clone-build.pkr.hcl.
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

Start-Transcript -Path 'C:/Install/22-enable-icmp.txt' -Append

try {
    Write-Host "Enable ICMP Echo Request (ping)"

    # ICMPv4 Echo Request is type 8. ICMPv6 Echo Request is type 128 - type 8
    # is IPv4 only, so an ICMPv6 rule with type 8 matches nothing at all.
    $icmpRules = @(
        [pscustomobject]@{
            Name        = 'Homelab-Allow-ICMPv4-Echo-In'
            DisplayName = 'Allow inbound ICMPv4 Echo Request'
            Protocol    = 'ICMPv4'
            IcmpType    = '8'
        }
        [pscustomobject]@{
            Name        = 'Homelab-Allow-ICMPv6-Echo-In'
            DisplayName = 'Allow inbound ICMPv6 Echo Request'
            Protocol    = 'ICMPv6'
            IcmpType    = '128'
        }
    )

    # Older revisions of this script created rules with -DisplayName only, so
    # every run produced another auto-named duplicate. Clear those out.
    $legacyDisplayNames = @('Allow inbound ICMPv4', 'Allow inbound ICMPv6')
    foreach ($legacyName in $legacyDisplayNames) {
        $legacyRules = @(Get-NetFirewallRule -DisplayName $legacyName -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $icmpRules.Name })
        foreach ($legacyRule in $legacyRules) {
            Write-Host "Removing legacy duplicate firewall rule '$($legacyRule.Name)' ($legacyName)"
            Remove-NetFirewallRule -Name $legacyRule.Name
        }

        # Read back: Remove-NetFirewallRule throws on error, but confirm the
        # duplicates are actually gone rather than trusting that it returned.
        $stillThere = @(Get-NetFirewallRule -DisplayName $legacyName -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $icmpRules.Name })
        if ($stillThere.Count -gt 0) {
            throw "Legacy duplicate rule(s) still present after removal: $(($stillThere | ForEach-Object { $_.Name }) -join ', ')"
        }
    }

    foreach ($rule in $icmpRules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Updating existing firewall rule '$($rule.Name)'"
            Set-NetFirewallRule -Name $rule.Name -NewDisplayName $rule.DisplayName -Direction Inbound `
                -Protocol $rule.Protocol -IcmpType $rule.IcmpType -Action Allow -Profile Any -Enabled True
        }
        else {
            Write-Host "Creating firewall rule '$($rule.Name)'"
            New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName -Direction Inbound `
                -Protocol $rule.Protocol -IcmpType $rule.IcmpType -Action Allow -Profile Any -Enabled True | Out-Null
        }
    }

    # Verify the effect: read every rule back from the live firewall.
    foreach ($rule in $icmpRules) {
        $live = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if (-not $live) {
            throw "Firewall rule '$($rule.Name)' does not exist after configuration."
        }
        if ([string]$live.Enabled -ne 'True') {
            throw "Firewall rule '$($rule.Name)' is not enabled (Enabled=$([string]$live.Enabled))."
        }
        if ([string]$live.Direction -ne 'Inbound') {
            throw "Firewall rule '$($rule.Name)' has direction $([string]$live.Direction), expected Inbound."
        }
        if ([string]$live.Action -ne 'Allow') {
            throw "Firewall rule '$($rule.Name)' has action $([string]$live.Action), expected Allow."
        }
        # -NewDisplayName / -DisplayName is a write like any other; read it back.
        if ([string]$live.DisplayName -ne $rule.DisplayName) {
            throw "Firewall rule '$($rule.Name)' has display name '$([string]$live.DisplayName)', expected '$($rule.DisplayName)'."
        }

        $filter = $live | Get-NetFirewallPortFilter
        if ([string]$filter.Protocol -ne $rule.Protocol) {
            throw "Firewall rule '$($rule.Name)' has protocol $([string]$filter.Protocol), expected $($rule.Protocol)."
        }
        # IcmpType can be reported as "8" or "8:*" depending on the code filter.
        $liveIcmpType = ([string]$filter.IcmpType -split ':')[0]
        if ($liveIcmpType -ne $rule.IcmpType) {
            throw "Firewall rule '$($rule.Name)' has ICMP type $liveIcmpType, expected $($rule.IcmpType)."
        }

        Write-Host "Verified '$($rule.Name)': $($rule.Protocol) type $($rule.IcmpType), Enabled=$([string]$live.Enabled)"
    }

    Write-Host "ICMP Echo Request allowed and verified for IPv4 and IPv6"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE was left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "22-enable-icmp FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    # Optional debug hold so the error is readable before Packer destroys the VM.
    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    # Non-zero so the provisioner fails; the finally below still closes the
    # transcript. Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript
}
