###############################################################################
# Name:             998-cleanup.ps1
# Description:      Cleanup Windows VM prior to templating
# Author:           Daniel Whicker
# Date:             2024-05-29
###############################################################################

# Set preferences to control script behavior
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Continue"

# Proceeding with cleanup
Write-Host "Proceeding with cleanup."

try {
    # Delete Windows temp files
    Write-Host "Deleting Windows temporary files..."
    try {
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force
    }
    catch {
        Write-Host "Error deleting Windows temporary files: $_"
    }

    # Delete user temp files
    Write-Host "Deleting user temporary files..."
    try {
        Remove-Item -Path "${env:TEMP}\*" -Recurse -Force
    }
    catch {
        Write-Host "Error deleting user temporary files: $_"
    }

    # Clear Event Logs
    Write-Host "Clearing Event Logs..."
    try {
        Get-EventLog -LogName * | ForEach-Object {
            try {
                Clear-EventLog -LogName $_.Log
            }
            catch {
                Write-Host "Error clearing event log: $_"
            }
        }
    }
    catch {
        Write-Host "Error processing event logs: $_"
    }

    # Stop Windows Update service
    Write-Host "Stopping Windows Update service..."
    try {
        Stop-Service -Name wuauserv -Force
    }
    catch {
        Write-Host "Error stopping Windows Update service: $_"
    }

    # Clear Windows Update cache
    Write-Host "Clearing Windows Update cache..."
    try {
        Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force
    }
    catch {
        Write-Host "Error clearing Windows Update cache: $_"
    }

    # Remove leftover Windows update files
    Write-Host "Removing leftover Windows update files..."
    try {
        Remove-Item -Path "C:\Windows\SoftwareDistribution\*.*" -Recurse -Force
    }
    catch {
        Write-Host "Error removing leftover Windows update files: $_"
    }

    # Delete prefetch files
    Write-Host "Deleting prefetch files..."
    try {
        Remove-Item -Path "C:\Windows\Prefetch\*" -Recurse -Force
    }
    catch {
        Write-Host "Error deleting prefetch files: $_"
    }

    # Clean up the Recycle Bin
    Write-Host "Cleaning up the Recycle Bin..."
    try {
        Clear-RecycleBin -Force
    }
    catch {
        Write-Host "Error cleaning up the Recycle Bin: $_"
    }

    # Cleanup completed successfully
    Write-Host "Cleanup completed successfully."

    # Clean up the Transcripts
    Write-Host "Removing Installation Transcripts..."
    try {
        Remove-Item -Path "C:\Install\*.txt" -Force
    }
    catch {
        Write-Host "Error removing installation transcripts: $_"
    }

    Write-Host "All specified cleanup tasks completed, despite any errors encountered."
}
catch {
    Write-Host "An unexpected error occurred during cleanup: $_"
    exit 0
}
