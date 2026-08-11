###############################################################################
# Name:             20-enable-rdp.ps1
# Description:      Enable RDP - registry flags, the "Remote Desktop" firewall
#                   group and TermService - and verify each actually took
#                   effect, ending with a real listener check on TCP 3389.
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\20-enable-rdp.txt (append).
#   2. Sets fDenyTSConnections to 0 under
#      HKLM\System\CurrentControlSet\Control\Terminal Server.
#   3. Sets UserAuthentication (NLA) to 1 under that key's
#      WinStations\RDP-Tcp subkey.
#   4. Enables the "Remote Desktop" firewall display group and then narrows
#      the result to the one rule that matters.
#   5. Starts TermService if it is not already Running.
#   6. Polls up to 90s (30 x 3s) for something to be listening on TCP 3389.
#
# WHAT IT VERIFIES
#   - fDenyTSConnections reads back as 0. Otherwise RDP is still disabled.
#   - The WinStations\RDP-Tcp key exists before writing NLA, and
#     UserAuthentication reads back as 1. The key check exists because
#     -ErrorAction SilentlyContinue used to turn a missing key into a silent
#     skipped write.
#   - At least one firewall rule matches the "Remote Desktop" display group,
#     and at least one is Enabled after Enable-NetFirewallRule.
#   - Crucially, that among those there is an Enabled, Inbound, Allow rule
#     with protocol TCP and 3389 in its local ports. "Some rule in the group
#     is enabled" is too weak to be a real assertion: the group also holds UDP
#     and shadow rules, so it stays true while the one rule that matters is
#     still disabled.
#   - TermService is Running; otherwise RDP will not answer.
#   - The end-to-end effect: a socket is actually listening on TCP 3389.
#     Registry set plus service Running can both be true while the RDP-Tcp
#     WinStation never came up, and that only surfaces when someone tries to
#     connect to a finished template. Get-NetTCPConnection reads local listen
#     state, so it is not itself affected by the firewall - meaning this last
#     check proves the listener exists, not that it is reachable from
#     off-box; the firewall assertion above covers that half.
#
# FAILURE CONTRACT
#   FATAL     : fDenyTSConnections or UserAuthentication reading back wrong, a
#               missing RDP-Tcp key, no rules matching the "Remote Desktop"
#               display group, no enabled rule in it, no enabled inbound Allow
#               rule for TCP 3389, TermService not Running, or nothing
#               listening on 3389 after 90s. Each throws and exits 1.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD
#           Any non-empty value sleeps 3600s on the failure path so the
#           failure is readable before Packer destroys the VM. Unset: exit
#           immediately.
#
# NOTES
#   - The "Remote Desktop" display group name is localised on non-English
#     images, and here that is FATAL by design (unlike the cosmetic "Network
#     Discovery" tweak in 12-prepwork.ps1) - the error message says as much,
#     because silently shipping a template without RDP is worse.
#   - The listener poll is generous on purpose: the listener can lag the
#     fDenyTSConnections flip by a few seconds.
#   - The success `exit 0` lives INSIDE the try on purpose: Packer runs this
#     as `... ; exit $LastExitCode`, so falling off the end would hand the
#     build's verdict to whatever stale $LASTEXITCODE was left behind, and
#     placing it after the try/catch would mask a caught failure. `exit` still
#     runs the finally, so the transcript is closed.
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/20-enable-rdp.txt' -Append

try {
    Write-Host "Enabling RDP"
    $tsKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $rdpTcpKey = Join-Path $tsKey 'WinStations\RDP-Tcp'

    Set-ItemProperty -Path $tsKey -Name "fDenyTSConnections" -Value 0
    $fDeny = (Get-ItemProperty -Path $tsKey -Name 'fDenyTSConnections').fDenyTSConnections
    if ($fDeny -ne 0) {
        throw "fDenyTSConnections read back as '$fDeny', expected 0 (RDP still disabled)"
    }
    Write-Host "fDenyTSConnections verified 0"

    # NLA. The RDP-Tcp WinStation exists on every SKU that has RDS bits; if it
    # is genuinely absent, say so instead of silently skipping the write, which
    # is what -ErrorAction SilentlyContinue used to do.
    if (-not (Test-Path -LiteralPath $rdpTcpKey)) {
        throw "$rdpTcpKey does not exist; cannot configure NLA (UserAuthentication)"
    }
    Set-ItemProperty -Path $rdpTcpKey -Name "UserAuthentication" -Value 1
    $nla = (Get-ItemProperty -Path $rdpTcpKey -Name 'UserAuthentication').UserAuthentication
    if ($nla -ne 1) {
        throw "UserAuthentication (NLA) read back as '$nla', expected 1"
    }
    Write-Host "UserAuthentication (NLA) verified 1"

    Write-Host "Enable RDP Through Firewall"
    $rules = @(Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) {
        throw "No firewall rules matched the 'Remote Desktop' display group (localised group name?)"
    }
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

    $enabled = @(Get-NetFirewallRule -DisplayGroup "Remote Desktop" |
            Where-Object { $_.Enabled -eq 'True' })
    if ($enabled.Count -eq 0) {
        throw "'Remote Desktop' firewall rules exist but none are enabled after Enable-NetFirewallRule"
    }
    Write-Host "Remote Desktop firewall rules verified: $($enabled.Count) of $($rules.Count) enabled"

    # "Some rule in the group is enabled" is too weak to be a real assertion:
    # the group also holds UDP and shadow rules, so it stays true while the one
    # rule that matters -- inbound Allow on TCP 3389 -- is still disabled.
    $tcp3389 = @($enabled |
            Where-Object { "$($_.Direction)" -eq 'Inbound' -and "$($_.Action)" -eq 'Allow' } |
            Where-Object {
                $f = $_ | Get-NetFirewallPortFilter
                "$($f.Protocol)" -eq 'TCP' -and (("$($f.LocalPort)" -split ',') -contains '3389')
            })
    if ($tcp3389.Count -eq 0) {
        throw "No enabled inbound Allow rule for TCP 3389 in the 'Remote Desktop' group; RDP would still be blocked"
    }
    Write-Host "Inbound Allow TCP/3389 verified: $(($tcp3389 | ForEach-Object { $_.Name }) -join ', ')"

    # The listener itself has to be up, otherwise the registry says yes and the
    # port still refuses connections.
    $svc = Get-Service -Name TermService
    if ($svc.Status -ne 'Running') {
        Write-Host "TermService is $($svc.Status); starting it"
        Start-Service -Name TermService
        $svc = Get-Service -Name TermService
    }
    if ($svc.Status -ne 'Running') {
        throw "TermService is not Running (status: $($svc.Status)); RDP will not answer"
    }
    Write-Host "TermService verified: $($svc.Status)"

    # The end-to-end effect: something must actually be bound to TCP 3389.
    # Registry set + service Running can both be true while the RDP-Tcp
    # WinStation never came up, and that only surfaces when someone tries to
    # connect to a finished template. Get-NetTCPConnection enumerates local
    # listen state, so it is not itself affected by the firewall.
    # The listener can lag the fDenyTSConnections flip by a few seconds.
    $listening = $null
    for ($i = 0; $i -lt 30; $i++) {
        $listening = @(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        if ($listening.Count -gt 0) { break }
        Start-Sleep -Seconds 3
    }
    if ($listening.Count -eq 0) {
        throw "Nothing is listening on TCP 3389 after 90s; RDP is enabled on paper only"
    }
    Write-Host "RDP listener verified: $($listening.Count) socket(s) listening on TCP 3389"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE was left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "Enabling RDP FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    if ($env:PACKER_DEBUG_HOLD) {
        Write-Host "PACKER_DEBUG_HOLD set; sleeping 3600s before exiting"
        Start-Sleep -Seconds 3600
    }

    # Non-zero so the provisioner fails; the finally below still closes the
    # transcript. Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
