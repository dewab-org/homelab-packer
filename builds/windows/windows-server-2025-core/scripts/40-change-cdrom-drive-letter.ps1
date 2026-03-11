###############################################################################
# Name:             40-change-cdrom-drive-letter.ps1
# Description:      Change the CD-ROM drive letter to the specified letter
# Author:           Daniel Whicker
# Date:             2024-07-09
###############################################################################

# Set the target drive letter here
$targetDriveLetter = "Z"

# Start transcript to log actions
$logPath = 'C:/Install/40-change-cdrom-drive-letter.txt'
Start-Transcript -Path $logPath -Append -Force

$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'

# Check if running in Azure
$headers = @{"Metadata" = "true" }
$response = Invoke-RestMethod -Headers $headers -Method GET -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -ErrorAction SilentlyContinue
if ($response) {
    Write-Host "Script is running on an Azure VM. Exiting script."
    Stop-Transcript
    exit
}

Write-Host "Changing CD-ROM drive letter from D: to $targetDriveLetter..."

try {
    # Get the CD-ROM drive
    $cdrom = Get-WmiObject -Query "SELECT * FROM Win32_CDROMDrive WHERE Drive = 'D:'"

    if ($cdrom) {
        # Get the current drive letter of the CD-ROM
        $currentDriveLetter = ($cdrom.Drive).Substring(0, 1)

        Write-Host "Current CD-ROM drive letter is: $currentDriveLetter"

        # Change the drive letter to the target drive letter
        $volume = Get-WmiObject -Query "SELECT * FROM Win32_Volume WHERE DriveLetter = 'D:'"
        if ($volume) {
            Set-WmiInstance -InputObject $volume -Arguments @{DriveLetter = $targetDriveLetter + ":" }
            Write-Host "CD-ROM drive letter successfully changed to $targetDriveLetter."
        }
        else {
            Write-Host "No volume found with drive letter D:."
        }
    }
    else {
        Write-Host "No CD-ROM drive found."
    }
}
catch {
    Write-Error "An error occurred: $_"
}

# Stop transcript
Stop-Transcript

Write-Host "Script execution completed successfully."
