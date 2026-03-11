###############################################################################
# Name:             58-install-non-choco-software.ps1
# Description:
# Author:           Daniel Whicker
# Date:             2021-10-27
###############################################################################

###############################################################################
# Software Details
###############################################################################
$installers = @(
    @{
        description = "SecureCRT/SecureFX";
        url         = "https://filebrowser.home.bifrost.cc/api/public/dl/0PyK3ZkJ/packer_build_files/windows/scrt-sfx-x64-bsafe.9.5.0.3241.exe";
        path        = "C:\Install\scrt-sfx.exe";
        args        = '/s /v"/qn"';
    }
    #    @{
    #    description = "TextExpander";
    #    url = "http://bifrost.viking.org/windows/Windows_Kit/TextExpanderSetup-7.0.1.exe";
    #    path = "C:\Install\textexpander.exe";
    #    args = '/install /q'
    #    }
)

# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/58-install-non-choco-software.txt' -Append;

try {
    foreach ($item in $installers) {
        Write-Host "Download $($item.description)"
        Invoke-WebRequest -Uri $($item.url) -OutFile $($item.path) -UseBasicParsing

        Write-Host "Install $($item.description)"
        Start-Process -FilePath $($item.path) -ArgumentList $($item.args) -Verbose -Wait
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
