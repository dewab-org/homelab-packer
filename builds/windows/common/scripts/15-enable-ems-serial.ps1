# Enable EMS/SAC so Windows actually emits console output to the serial port
# (COM1 == Proxmox serial0). The serials=["socket"] device alone is inert
# without this. Configure the OS loader + boot manager for EMS on COM1, then
# read the BCD store back and fail the build if it did not take (validate,
# never assume success — native bcdedit does not throw on error).
$ErrorActionPreference = 'Stop'

& bcdedit /ems '{current}' on                        | Out-Null
& bcdedit /bootems '{current}' on                    | Out-Null
& bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200  | Out-Null

$current = & bcdedit /enum '{current}'
if (-not ($current | Select-String -Pattern '^\s*ems\s+Yes' -Quiet)) {
    Write-Error ("EMS not enabled on {current} after bcdedit:`n" + ($current -join "`n"))
    exit 1
}

$settings = & bcdedit /enum '{emssettings}'
if (-not ($settings | Select-String -Pattern 'emsport' -Quiet)) {
    Write-Error ("emssettings (EMSPORT/EMSBAUDRATE) not applied:`n" + ($settings -join "`n"))
    exit 1
}

Write-Host 'EMS/SAC enabled and verified: COM1 @ 115200'
