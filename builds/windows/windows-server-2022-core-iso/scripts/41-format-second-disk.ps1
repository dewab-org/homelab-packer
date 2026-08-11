###############################################################################
# Name:             41-format-second-disk.ps1
# Description:      Mark disk 1 as online, format as NTFS, and label as specified
# Author:           Daniel Whicker
# Date:             2024-07-09
###############################################################################

# Set the label name and drive letter here
$labelName = "Admin"
$driveLetter = "D"

# Start transcript to log actions
$logPath = 'C:/Install/41-format-second-disk.txt'
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

Write-Host "Checking if disk 1 is present..."

try {
    # Check if disk 1 is present
    $disk = Get-Disk -Number 1 -ErrorAction Stop

    Write-Host "Disk 1 is present. Proceeding with operations..."

    # Check if the disk is offline and bring it online if it is
    if ($disk.IsOffline -eq $true) {
        Write-Host "Disk 1 is offline. Bringing it online..."
        Set-Disk -Number 1 -IsOffline $false
    }

    # Check if the disk is read-only and set it to read/write if it is
    if ($disk.IsReadOnly -eq $true) {
        Write-Host "Disk 1 is read-only. Setting it to read/write..."
        Set-Disk -Number 1 -IsReadOnly $false
    }

    # Initialize the disk if it is not initialized
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Host "Disk 1 is not initialized. Initializing..."
        Initialize-Disk -Number 1 -PartitionStyle GPT
    }
    else {
        Write-Host "Disk 1 is already initialized."
    }

    # Check if the disk has any partitions
    $partitions = Get-Partition -DiskNumber 1
    if ($partitions) {
        Write-Host "Disk 1 already has a partition. Formatting existing partition..."

        # Format the existing partition as NTFS
        $partition = $partitions[0]
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $labelName

        # Assign the specified drive letter
        Write-Host "Assigning drive letter '$driveLetter' to the partition..."
        Set-Partition -DiskNumber 1 -PartitionNumber $partition.PartitionNumber -NewDriveLetter $driveLetter
    }
    else {
        Write-Host "Disk 1 has no partitions. Creating new partition..."

        # Create a new partition and format it as NTFS
        $partition = New-Partition -DiskNumber 1 -UseMaximumSize
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $labelName

        # Assign the specified drive letter
        Write-Host "Assigning drive letter '$driveLetter' to the partition..."
        Set-Partition -DiskNumber 1 -PartitionNumber $partition.PartitionNumber -NewDriveLetter $driveLetter
    }

    Write-Host "Disk 1 has been successfully formatted, labeled as '$labelName', and assigned drive letter '$driveLetter'."
}
catch {
    if ($_.Exception -match "Cannot find disk with number") {
        Write-Host "Disk 1 is not present. Skipping operations."
    }
    else {
        Write-Error "An error occurred: $_"
    }
}

# Stop transcript
Stop-Transcript

Write-Host "Script execution completed successfully."
