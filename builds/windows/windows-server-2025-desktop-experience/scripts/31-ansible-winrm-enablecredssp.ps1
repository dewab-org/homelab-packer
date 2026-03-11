###############################################################################
# Name:             31-ansible-winrm-enablecredssp.ps1
# Description:      Enable CredSSP for WINRM Authentication
# Author:           Daniel Whicker
# Date:             2022-03-03
###############################################################################

Start-Transcript -Path 'C:/Install/31-ansible-winrm-enablecredssp.txt' -Append;

$VerbosePreference = 'Continue';
$InformationPreference = 'Continue';

Write-Host "Configuring WSman with CredSSP"

Enable-WSManCredSSP -role server -Force
