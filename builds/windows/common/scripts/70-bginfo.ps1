###############################################################################
# Name:             70-bginfo.ps1
# Description:      Configure BGInfo to run at startup
# Author:           Daniel Whicker
# Date:             2021-11-09
###############################################################################

###############################################################################
# Variables
###############################################################################

$configUrl = "https://filebrowser.home.bifrost.cc/api/public/dl/C6mKNZbB/packer_build_files/windows/myconfig.bgi"
$configDir = "C:\BGInfo"
$bgiRegistryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$bgiRegistryValue = "$bgiPath $configDir\logon.bgi /timer:0 /nolicprompt"
$logFile = "C:/Install/70-bginfo.txt"

###############################################################################
# Functions
###############################################################################

function Show-Log {
    param (
        [string]$message
    )
    Write-Host $message
    Add-Content -Path $logFile -Value $message
}

function Find-BGInfoPath {
    $candidates = @(
        "C:\Program Files\BGInfo\Bginfo64.exe",
        "C:\Program Files (x86)\BGInfo\Bginfo64.exe",
        "C:\Program Files\Sysinternals\Bginfo64.exe",
        "C:\Program Files (x86)\Sysinternals\Bginfo64.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $match = Get-ChildItem -Path "C:\Program Files", "C:\Program Files (x86)" -Filter "Bginfo64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) {
        return $match.FullName
    }

    throw "Bginfo64.exe not found"
}

function Get-ConfigFile {
    Show-Log "Downloading config file from $configUrl"
    Invoke-WebRequest -Uri $configUrl -OutFile "$configDir\logon.bgi" -UseBasicParsing
}

function Set-Registry {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string]$bgiRegistryKey,
        [string]$bgiRegistryValue
    )
    Show-Log "Configuring registry key for BGInfo"
    if (Test-Path "$bgiRegistryKey\BgInfo") {
        Show-Log "Removing existing registry key"
        Remove-ItemProperty -Path $bgiRegistryKey -Name "BgInfo" -Force
    }
    Show-Log "Creating new registry key"
    New-ItemProperty -Path $bgiRegistryKey -Name "BgInfo" -PropertyType String -Value $bgiRegistryValue -Force
}

function Invoke-BGInfo {
    Show-Log "Running BGInfo with the downloaded configuration"
    & $bgiPath "$configDir\logon.bgi" /timer:0 /nolicprompt
}

###############################################################################
# Main
###############################################################################

# Terminate entire script if an exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path $logFile -Append

try {
    Show-Log "Creating directory $configDir"
    New-Item -ItemType Directory -Force -Path $configDir
    $bgiPath = Find-BGInfoPath
    $bgiRegistryValue = "$bgiPath $configDir\logon.bgi /timer:0 /nolicprompt"

    Get-ConfigFile
    Set-Registry
    Invoke-BGInfo
}
catch {
    Show-Log "Something went wrong: $($_.Exception.Message)"

    Exit 1
}
finally {
    Stop-Transcript
}
