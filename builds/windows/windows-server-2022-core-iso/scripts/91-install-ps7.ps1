###############################################################################
# Name:             91-install-ps7.ps1
# Description:      Install PowerShell 7
# Author:           Daniel Whicker
# Date:             2021-09-08
###############################################################################

Start-Transcript -Path 'C:/Install/91-install-ps7.txt' -Append;

Write-Host "Installing PowerShell 7"

# Download installer script
$url = "https://aka.ms/install-powershell.ps1"
$outputPath = "C:/Install/install-powershell.ps1"
Invoke-WebRequest -Uri $url -OutFile $outputPath

# Execute installer script
& $outputPath -UseMSI
