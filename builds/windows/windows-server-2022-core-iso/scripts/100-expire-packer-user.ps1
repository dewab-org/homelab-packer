###############################################################################
# Name:             100-expire-packer-user.ps1
# Description:      Rename default users
# Author:           Daniel Whicker
# Date:             2024-05-02
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/100-expire-packer-user.txt' -Append

# Set the username to expire
$username = "packer"

# Calculate the expiration date (1 day from now)
$expirationDate = (Get-Date).AddDays(1)

# Check if the user exists
$user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
if ($null -eq $user) {
    Write-Host "Local user '$username' not found."
    Stop-Transcript
    Exit
}

# Set the account expiration date using Set-LocalUser
try {
    $user | Set-LocalUser -AccountExpires $expirationDate
    Write-Host "Local user '$username' has been set to expire on $($expirationDate.ToString('MM/dd/yyyy'))."
}
catch {
    Write-Host "Failed to set the expiration date for user '$username'."
}

Stop-Transcript
