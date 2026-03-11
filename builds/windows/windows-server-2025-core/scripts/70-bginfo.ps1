###############################################################################
# Name:             70-bginfo.ps1
# Description:      Configure BGInfo to run at startup
# Author:           Daniel Whicker
# Date:             2021-11-09
###############################################################################

# Assumes that bginfo has already been installed prior to running, perhaps
# via chocolatey

###############################################################################
# Variables
###############################################################################

$configUrl = "https://filebrowser.home.bifrost.cc/api/public/dl/C6mKNZbB/packer_build_files/windows/myconfig.bgi"
$configDir = "C:\BGInfo"
$bgiRegistryKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$bgiPath = "C:\ProgramData\chocolatey\bin\bginfo64.exe"
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

    Get-ConfigFile
    Set-Registry
    Invoke-BGInfo
}
catch {
    Show-Log "Something went wrong: $($_.Exception.Message)"
    Show-Log "Sleeping for 60 minutes before VM is destroyed by Packer"

    # Sleep for 60 minutes so you can see the errors before the VM is destroyed by Packer.
    Start-Sleep -Seconds 3600

    Exit 1
}
finally {
    Stop-Transcript
}
