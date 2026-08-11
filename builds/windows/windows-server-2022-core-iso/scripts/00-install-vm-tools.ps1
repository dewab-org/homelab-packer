# Terminate entire script if exception occurs.
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

$vmwaretools_path = "E:\setup.exe"
$install_arguments = "/s /v /qn REBOOT=ReallySuppress"

Start-Transcript -Path 'C:/Install/00-vmtools.txt' -Append;

try {
    Write-Output "Installing VMware Tools"
    Start-Process -FilePath $vmwaretools_path -ArgumentList $install_arguments -Verbose -Wait
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

Start-Sleep -Seconds 10
