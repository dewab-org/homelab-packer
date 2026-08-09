# Install the homelab CA chain into the machine certificate stores.
#
# Parity with the Linux templates, which install these same certificates into
# /etc/pki/ca-trust. Without them a Windows clone cannot validate TLS against
# anything signed by the lab CA (vault.viking.org, *.k3s.lab.local, ...).
#
# Installed from the bootstrap CD, NOT downloaded. An earlier version fetched
# the certs from web.viking.org with Invoke-WebRequest and failed with "the
# underlying connection was closed" — PowerShell 5.1's web stack against the
# nginx ingress, and forcing TLS 1.2 did not help. The certs are static files
# already in the repo (ca/root_ca_bundle.pem), so shipping them on the CD is
# both more robust and removes a build-time network dependency. Bonus: no
# chicken-and-egg where the mirror that serves the CA is itself CA-signed.
#
# Verified, not assumed: each import is confirmed by thumbprint lookup in the
# destination store afterwards, per the repo rule.

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/05-install-lab-ca.txt' -Append

try {
    # The CA bundle (PEM, root + intermediate concatenated) is delivered on the
    # bootstrap CD alongside the scripts. Find it by scanning the CD-ROM roots,
    # the same way bootstrap.cmd locates its payload.
    $bundle = $null
    foreach ($d in (Get-WmiObject Win32_LogicalDisk -Filter "DriveType=5" | Select-Object -ExpandProperty DeviceID)) {
        $candidate = Join-Path $d 'root_ca_bundle.pem'
        if (Test-Path $candidate) { $bundle = $candidate; break }
    }
    # Fall back to the copy bootstrap.ps1 stages into C:\Install.
    if (-not $bundle -and (Test-Path 'C:\Install\root_ca_bundle.pem')) {
        $bundle = 'C:\Install\root_ca_bundle.pem'
    }
    if (-not $bundle) { throw "root_ca_bundle.pem not found on any CD-ROM or in C:\Install" }
    Write-Host "Using CA bundle: $bundle"

    # Split the PEM into individual certs. The first (root, self-signed) goes to
    # the Root store; the rest (intermediate) to the CA store.
    $pem = Get-Content -Path $bundle -Raw
    $blocks = [regex]::Matches($pem, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----') |
        ForEach-Object { $_.Value }
    if ($blocks.Count -eq 0) { throw "No certificates found in $bundle" }
    Write-Host "Found $($blocks.Count) certificate(s) in the bundle"

    $i = 0
    foreach ($block in $blocks) {
        $i++
        # Write the PEM block to a temp file and construct the cert from the
        # PATH. Passing a byte[] to New-Object makes PowerShell unroll the array
        # into hundreds of positional args ("no overload ... argument count 614").
        $tmp = Join-Path $env:TEMP "labca-$i.crt"
        Set-Content -Path $tmp -Value $block -Encoding ASCII
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($tmp)
        # Self-signed (issuer == subject) is the root; everything else intermediate.
        $store = if ($cert.Issuer -eq $cert.Subject) { 'Root' } else { 'CA' }
        Write-Host "  [$i] $($cert.Subject)  ->  LocalMachine\$store  (thumbprint $($cert.Thumbprint))"
        Import-Certificate -FilePath $tmp -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        $found = Get-ChildItem "Cert:\LocalMachine\$store" |
            Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if (-not $found) {
            throw "$($cert.Subject) reported imported but is not present in LocalMachine\$store"
        }
        Write-Host "      verified present in LocalMachine\$store"
    }

    # End-to-end proof: with the chain trusted, a TLS call to a lab-CA-signed
    # host must now validate. Non-fatal if the host is unreachable from the
    # build network — the imports above are the real deliverable.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri 'https://web.viking.org/tmp/certs/root_ca.crt' -UseBasicParsing -Method Head -TimeoutSec 15
        Write-Host "TLS validation against a lab-CA host works (HTTP $($r.StatusCode))"
    } catch {
        Write-Host "Post-install TLS probe skipped/failed (non-fatal): $($_.Exception.Message)"
    }
}
catch {
    Write-Host
    Write-Host "Something went wrong:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host
    Exit 1
}
finally {
    Stop-Transcript
}
