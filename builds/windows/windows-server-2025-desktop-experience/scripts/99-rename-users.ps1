###############################################################################
# Name:             99-rename-users.ps1
# Description:      Rename default users or create them if they don't exist
# Author:           Daniel Whicker
# Date:             2024-05-23
###############################################################################

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/99-rename-users.txt' -Append;

$userMapping = @(
    @{
        OldName  = "Administrator"
        NewName  = "990353"
        Disabled = $false
        Password = (ConvertTo-SecureString $Env:ADMIN_PASSWORD -AsPlainText -Force)
        Group    = "Administrators"
    },
    @{
        OldName  = "Guest"
        NewName  = "990350"
        Disabled = $true
        Password = (ConvertTo-SecureString $Env:ADMIN_PASSWORD -AsPlainText -Force)
        Group    = "Guests"
    }
)

function RenameOrCreateUser {
    param (
        [string]$OldName,
        [string]$NewName,
        [securestring]$Password,
        [string]$Group,
        [bool]$Disabled
    )

    $existingUser = Get-LocalUser -Name $OldName -ErrorAction SilentlyContinue
    if ($existingUser) {
        Rename-LocalUser -Name $OldName -NewName $NewName
        Write-Host "$OldName account has been renamed to $NewName"
    }
    else {
        $newUser = Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue
        if (-not $newUser) {
            New-LocalUser -Name $NewName -AccountNeverExpires -PasswordNeverExpires -Password $Password
            Add-LocalGroupMember -Group $Group -Member $NewName
            Write-Host "$NewName account has been created and added to the $Group group"
        }
        else {
            Write-Host "$NewName already exists"
        }
    }

    # Disable the user if necessary
    if ($Disabled) {
        Disable-LocalUser -Name $NewName
        Write-Host "$NewName account has been disabled"
    }
}

try {
    foreach ($user in $userMapping) {
        RenameOrCreateUser -OldName $user.OldName -NewName $user.NewName -Password $user.Password -Group $user.Group -Disabled $user.Disabled
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host

    # Sleep for 60 minutes so you can see the errors before the VM is destroyed by Packer.
    Start-Sleep -Seconds 3600

    Exit 1
}
