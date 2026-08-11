###############################################################################
# Name:             20-set-temp.ps1
# Description:      Set Windows temporary directories and variables
# Author:           Daniel Whicker
# Date:             2021-05-30
###############################################################################

Start-Transcript -Path 'C:/Install/20-set-temp.txt' -Append;

$VerbosePreference = 'Continue';
$InformationPreference = 'Continue';

Write-Host "Configuring temp folder"
$TempFolder = "C:\TEMP";
New-Item -ItemType Directory -Force -Path $TempFolder;
[Environment]::SetEnvironmentVariable("TEMP", $TempFolder, [EnvironmentVariableTarget]::Machine);
[Environment]::SetEnvironmentVariable("TMP", $TempFolder, [EnvironmentVariableTarget]::Machine);
[Environment]::SetEnvironmentVariable("TEMP", $TempFolder, [EnvironmentVariableTarget]::User);
[Environment]::SetEnvironmentVariable("TMP", $TempFolder, [EnvironmentVariableTarget]::User);
