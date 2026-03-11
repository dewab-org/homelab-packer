###############################################################################
# Name:             23-convert-evaluation-to-standard.ps1
# Description:      Convert Windows Server 2022 from Evaluation to Standard
#                   Only run if the current version is in evaluation mode
# Author:           Daniel Whicker
# Date:             2024-07-08
###############################################################################

# Set the product key here
$productKey = "VDYBN-27WPP-V4HQT-9VMD4-VMK7H"

# Start transcript to log actions
$logPath = 'C:/Install/23-convert-evaluation-to-standard.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

Write-Host "Checking if Windows is in evaluation mode..."

# Function to check if running in evaluation mode
function Test-EvaluationVersion {
    try {
        $currentEdition = (Get-WmiObject -Class Win32_OperatingSystem).OperatingSystemSKU
        if ($currentEdition -ne 7 -and $currentEdition -ne 8) {
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        Write-Error "Failed to determine the current edition: $_"
        return $false
    }
}

# Function to convert evaluation to standard
function Convert-EvaluationToStandard {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProductKey
    )

    # Convert to standard edition
    $cmd = "dism /online /Set-Edition:ServerStandard /ProductKey:$ProductKey /AcceptEula"
    Write-Output "Executing: $cmd"
    Invoke-Expression $cmd

    Write-Output "Conversion to Standard edition initiated. Please restart the computer to complete the process."
    return $null
}

# Check if running in evaluation mode
if (Test-EvaluationVersion) {
    Write-Host "Evaluation version detected. Proceeding with conversion."

    try {
        # Execute the conversion function
        Convert-EvaluationToStandard -ProductKey $productKey
    }
    catch {
        Write-Error "An error occurred during the conversion process, but the script will continue."
    }
}
else {
    Write-Host "This script is only for Windows Server Evaluation editions. Exiting."
}

# Stop transcript
Stop-Transcript

# Needed as the conversion errors with 1168 and requires a restart
exit 0
