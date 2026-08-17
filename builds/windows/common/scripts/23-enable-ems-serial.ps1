###############################################################################
# Name:             23-enable-ems-serial.ps1
# Description:      Turns on EMS/SAC so Windows emits console output to the
#                   serial port (COM1 == Proxmox serial0) at 115200 baud,
#                   configuring both the OS loader and the boot manager via
#                   bcdedit, then re-reading the BCD store and failing the
#                   build if any of it did not take.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Creates C:\Install and opens a transcript at
#      C:\Install\23-enable-ems-serial.txt.
#   2. Defines Invoke-BcdEdit, which runs bcdedit.exe, retries a /enum that
#      comes back empty via cmd.exe (an elevated scheduled task has no console
#      and bcdedit has been seen producing nothing there), and throws on a
#      non-zero $LASTEXITCODE (bcdedit does not throw and does not honour
#      $ErrorActionPreference), and Get-BcdElementValue, which scrapes a
#      named element's value out of 'bcdedit /enum' text.
#   3. bcdedit /ems {current} on
#        -> EMS on the OS LOADER object: console redirection once Windows
#           itself is running.
#   4. bcdedit /bootems {bootmgr} on
#        -> EMS on the BOOT MANAGER object: console redirection during the
#           boot menu, before the OS loader takes over.
#   5. bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200
#        -> the global {emssettings} object: port and speed shared by both
#           of the above. EMSPORT:1 means COM1.
#
# WHAT IT VERIFIES
#   - 'bcdedit /enum {current}' reports ems=Yes. Anything else means the OS
#     loader will boot with redirection off.
#   - 'bcdedit /enum {bootmgr}' reports bootems=Yes. This is a separate BCD
#     object from {current} and has to be asserted separately - see NOTES.
#   - 'bcdedit /enum {emssettings}' reports emsport=1 and emsbaudrate=115200.
#     Both values are compared explicitly rather than merely checking that
#     the word 'emsport' appears, because bcdedit prints emsport with a
#     default value even when nothing was applied - a presence check would
#     pass on a store where the setting never landed.
#   - Every bcdedit invocation is checked for exit code 0 via Invoke-BcdEdit.
#
#   NOT VERIFIED, and it cannot be from inside the guest: whether Proxmox
#   actually attached a serial device to this VM. All this script proves is
#   that Windows is configured to emit on COM1. If the VM has no
#   serials=["socket"] device, every assertion here still passes and the
#   output goes nowhere.
#
# FAILURE CONTRACT
#   FATAL     : any bcdedit call exiting non-zero; ems != Yes on {current};
#               bootems != Yes on {bootmgr}; emsport != 1; emsbaudrate !=
#               115200. All exit 1 and fail the provisioner. The full
#               'bcdedit /enum' output is included in the thrown message so
#               the transcript shows the store as it actually was.
#
# INPUTS (environment)
#   PACKER_DEBUG_HOLD   When set to any value, the catch block sleeps 3600s
#                       before exiting 1 so the error stays readable before
#                       Packer destroys the VM. Unset: exit immediately.
#
# NOTES
#   - /bootems belongs on {bootmgr}, not {current}. The boot manager is the
#     object that emits EMS output before the OS loader is even reached;
#     setting EMS on {current} alone is exactly why serial output used to be
#     missing from the boot menu. Two different objects, two different
#     switches, two separate assertions - do not collapse them.
#   - The Proxmox serials=["socket"] device is inert on its own. Without
#     this script the guest simply never writes to it, which looks
#     identical to a broken socket from the host side.
#   - Get-BcdElementValue matches '<element> <single-token>' anchored to a
#     whole line, so it is deliberately strict about bcdedit's column
#     layout; a value containing spaces would read as $null and fail loudly
#     rather than partially match.
#   - Wired into every Windows build: the 2022 and 2025 Core and Desktop
#     Experience ISO builds, and common/cloud-clone-build.pkr.hcl.
###############################################################################
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path 'C:/Install' | Out-Null
Start-Transcript -Path 'C:/Install/23-enable-ems-serial.txt' -Append

function Invoke-BcdEdit {
    [CmdletBinding()]
    # 2>&1 can yield ErrorRecords, so the static type is object[] even though
    # every element is stringified on the way out.
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        # Set to $true for /enum queries, whose output is the whole point.
        [switch]$ExpectOutput
    )

    $output = @(& bcdedit.exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("bcdedit " + ($Arguments -join ' ') + " failed with exit code ${code}:`n" + ($output -join "`n"))
    }

    # /enum queries MUST produce output; a set operation legitimately produces
    # little or none. An empty /enum is not a parse problem, it is a failed
    # read, and it has to say so here rather than surfacing downstream as
    # "Cannot bind argument ... because it is an empty string".
    #
    # It happens for real: under Packer's elevated_user provisioner the script
    # runs from a scheduled task with no console attached, and bcdedit has been
    # observed returning nothing there while the same command works
    # interactively. Re-running it through cmd.exe gives it a console and the
    # output comes back, so that is the fallback rather than a hard failure.
    if ($ExpectOutput -and ($output.Count -eq 0 -or ($output -join '').Trim() -eq '')) {
        Write-Host "  bcdedit $($Arguments -join ' ') returned no output; retrying via cmd.exe (no console in an elevated task)"
        $joined = ($Arguments | ForEach-Object { $_ }) -join ' '
        $output = @(& cmd.exe /c "bcdedit.exe $joined" 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw ("bcdedit " + $joined + " (via cmd.exe) failed with exit code ${code}:`n" + ($output -join "`n"))
        }
        if ($output.Count -eq 0 -or ($output -join '').Trim() -eq '') {
            throw ("bcdedit " + $joined + " returned no output even via cmd.exe, so the BCD store could not be read back. EMS cannot be verified.")
        }
    }
    return $output
}

function Get-BcdElementValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$EnumOutput,

        [Parameter(Mandatory = $true)]
        [string]$Element
    )

    $pattern = '^\s*' + [regex]::Escape($Element) + '\s+(?<value>\S+)\s*$'
    $match = $EnumOutput | Select-String -Pattern $pattern | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.Matches[0].Groups['value'].Value
}

try {
    Invoke-BcdEdit -Arguments @('/ems', '{current}', 'on') | Out-Null
    Invoke-BcdEdit -Arguments @('/bootems', '{bootmgr}', 'on') | Out-Null
    Invoke-BcdEdit -Arguments @('/emssettings', 'EMSPORT:1', 'EMSBAUDRATE:115200') | Out-Null

    # Verify the effect: EMS enabled on the OS loader entry.
    $current = Invoke-BcdEdit -Arguments @('/enum', '{current}') -ExpectOutput
    $ems = Get-BcdElementValue -EnumOutput $current -Element 'ems'
    if ($ems -ne 'Yes') {
        throw ("EMS not enabled on {current} (ems=" + $ems + "):`n" + ($current -join "`n"))
    }

    # Verify the effect: EMS enabled on the boot manager.
    $bootmgr = Invoke-BcdEdit -Arguments @('/enum', '{bootmgr}') -ExpectOutput
    $bootems = Get-BcdElementValue -EnumOutput $bootmgr -Element 'bootems'
    if ($bootems -ne 'Yes') {
        throw ("bootems not enabled on {bootmgr} (bootems=" + $bootems + "):`n" + ($bootmgr -join "`n"))
    }

    # Verify the effect: the actual port and baud rate, not just the presence
    # of the word 'emsport' - bcdedit prints emsport with a default value even
    # when nothing was applied.
    $settings = Invoke-BcdEdit -Arguments @('/enum', '{emssettings}') -ExpectOutput
    $emsPort = Get-BcdElementValue -EnumOutput $settings -Element 'emsport'
    $emsBaud = Get-BcdElementValue -EnumOutput $settings -Element 'emsbaudrate'
    if ($emsPort -ne '1') {
        throw ("emsport is '" + $emsPort + "', expected 1:`n" + ($settings -join "`n"))
    }
    if ($emsBaud -ne '115200') {
        throw ("emsbaudrate is '" + $emsBaud + "', expected 115200:`n" + ($settings -join "`n"))
    }

    Write-Host 'EMS/SAC enabled and verified: {current} ems=Yes, {bootmgr} bootems=Yes, COM1 @ 115200'

    # Explicit success code. Packer's default powershell execute_command ends
    # with 'exit $LastExitCode', which would otherwise propagate whatever the
    # last native command (bcdedit) left behind.
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
