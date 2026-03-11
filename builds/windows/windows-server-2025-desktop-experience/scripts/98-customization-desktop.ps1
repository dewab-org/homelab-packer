###############################################################################
# Name:             98-customization-desktop.ps1
# Description:      Customize desktop installation of Windows
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################


# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$xpackages = @(
    '*3dbuilder*',
    '*windowsalarms*',
    '*windowscommunicationsapps*',
    '*windowscamera*',
    '*skypeapp*',
    '*getstarted*',
    '*zunemusic*',
    '*windowsmaps*',
    '*solitairecollection*',
    '*bingfinance*',
    '*zunevideo*',
    '*bingnews*',
    '*onenote*',
    #'*people*',
    '*windowsphone*',
    '*photos*',
    '*bingsports*',
    '*soundrecorder*',
    '*bingweather*',
    '*xboxapp*'
)

Start-Transcript -Path 'C:/Install/98-customization-desktop.txt' -Append

try {
    if (-not (Test-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search")) {
        New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" | Out-Null
    }
    if (-not (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced")) {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" | Out-Null
    }
    if (-not (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer")) {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" | Out-Null
    }

    # Remove Cortana from taskbar
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value "0"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCortanaButton" -Value "0"

    # Stop autohiding notification area
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" -Name "EnableAutoTray" -Value "0"

    # Remove obnoxious packages
    foreach ($package in $xpackages) {
        Write-Host "Removing package $package."
        try {
            $packages = Get-AppxPackage -Name $package -ErrorAction SilentlyContinue
            foreach ($pkg in $packages) {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Host "Skipping package $package: $($_.Exception.Message)"
        }
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    Exit 1
}

Start-Sleep -Seconds 10
