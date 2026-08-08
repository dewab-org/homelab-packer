###############################################################################
# Name:             59-install-winget.ps1
# Description:      Installs desktop applications using Winget
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$WingetPackages = @(
    '7zip.7zip',
    'Git.Git',
    'Google.Chrome',
    'JAMSoftware.TreeSize.Free',
    'Microsoft.RemoteDesktopConnectionManager',
    'Microsoft.Sysinternals.BGInfo',
    'Microsoft.Sysinternals.ProcessExplorer',
    'Microsoft.VisualStudioCode',
    'Microsoft.WindowsTerminal',
    'Mozilla.Firefox',
    'Notepad++.Notepad++'
)

function Install-Winget {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        return
    }

    Write-Host "Winget is not installed. Installing dependencies and Winget."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Add-AppxPackage -Path 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
    Add-AppxPackage -Path 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
}

Start-Transcript -Path 'C:/Install/59-install-winget.txt' -Append

try {
    Install-Winget

    foreach ($PackageId in $WingetPackages) {
        Write-Host "Installing $PackageId"
        & winget install --id $PackageId --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Winget failed for $PackageId with exit code $LASTEXITCODE"
        }
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($_.Exception.Message)
    Write-Host
    Exit 1
}
finally {
    Stop-Transcript
}
