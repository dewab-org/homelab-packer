###############################################################################
# Name:             11-install-lab-ca.ps1
# Description:      Split root_ca_bundle.pem off the bootstrap CD into
#                   individual certificates, import each into LocalMachine
#                   Root or CA, and gate on the chain actually validating.
# Author:           Daniel Whicker
# Date:             2026-08-11
###############################################################################
#
# WHAT IT DOES
#   1. Starts a transcript at C:\Install\11-install-lab-ca.txt (append).
#   2. Scans CD-ROM logical disks (DriveType=5) for root_ca_bundle.pem, then
#      falls back to the copy bootstrap.ps1 stages into C:\Install.
#   3. Regex-extracts every BEGIN/END CERTIFICATE block from the bundle.
#   4. For each block: writes it to a temp .crt, loads it as an
#      X509Certificate2, classifies it (issuer == subject -> Root, otherwise
#      CA), imports it into Cert:\LocalMachine\<store>, deletes the temp file
#      and collects the certificate.
#   5. Builds an X509Chain for every imported certificate against the machine
#      stores, with the imported set supplied as ExtraStore.
#
# WHAT IT VERIFIES
#   - The bundle is found on a CD-ROM or in C:\Install. Failure means no
#     certificates would have been installed at all.
#   - The bundle contains at least one certificate block. Failure means the
#     file is present but empty or malformed.
#   - After each import, the thumbprint is looked up in the destination store.
#     Failure means Import-Certificate reported success without landing it.
#   - Every imported certificate chains to a trusted root using only the
#     machine stores. This is the same trust decision Schannel makes, so a
#     failure means the template would not validate lab TLS either.
#   - Limit worth naming: revocation checking is explicitly disabled
#     (RevocationMode NoCheck) because there is no network during the build,
#     so signature, validity dates and trust path are proven - revocation
#     status is not.
#
# FAILURE CONTRACT
#   FATAL     : bundle not found, no certificate blocks in it, a certificate
#               missing from its destination store after import, or a chain
#               that fails to build. Each throws and exits 1, printing the
#               chain status detail where it has one.
#
# NOTES
#   - Parity with the Linux templates, which install these same certificates
#     into /etc/pki/ca-trust. Without them a Windows clone cannot validate TLS
#     against anything signed by the lab CA (vault.viking.org,
#     *.k3s.lab.local, ...).
#   - Installed from the bootstrap CD, NOT downloaded. An earlier version
#     fetched the certs from web.viking.org with Invoke-WebRequest and failed
#     with "the underlying connection was closed" - PowerShell 5.1's web stack
#     against the nginx ingress, and forcing TLS 1.2 did not help. The certs
#     are static files already in the repo (ca/root_ca_bundle.pem), so
#     shipping them on the CD is more robust and removes a build-time network
#     dependency. Bonus: no chicken-and-egg where the mirror that serves the
#     CA is itself CA-signed.
#   - The chain gate replaced a fake proof: an HTTPS HEAD against
#     web.viking.org wrapped in a catch-all that logged "non-fatal". It could
#     never fail, so it proved nothing, and it made the build depend on
#     network reachability. Chain building is local and deterministic.
#   - Two PowerShell traps encoded in the code: certificates are constructed
#     from a file PATH because passing a byte[] to New-Object unrolls the
#     array into hundreds of positional args ("no overload ... argument count
#     614"); and the regex matches are wrapped in @() so a single-certificate
#     bundle is still an array rather than a bare string with a misleading
#     .Count.
#   - The only step allowed to fail quietly is deleting the temp .crt: it has
#     already served its purpose, the import is asserted regardless, and a
#     leftover scratch file changes no outcome.
###############################################################################

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

Start-Transcript -Path 'C:/Install/11-install-lab-ca.txt' -Append

try {
    # The CA bundle (PEM, root + intermediate concatenated) is delivered on the
    # bootstrap CD alongside the scripts. Find it by scanning the CD-ROM roots,
    # the same way bootstrap.cmd locates its payload.
    $bundle = $null
    $cdDrives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=5" |
        Select-Object -ExpandProperty DeviceID
    foreach ($d in $cdDrives) {
        $candidate = Join-Path $d 'root_ca_bundle.pem'
        if (Test-Path -LiteralPath $candidate) { $bundle = $candidate; break }
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
    # @(...) so a single-certificate bundle is still an array: without it the
    # pipeline yields a bare string and .Count means something else entirely.
    $blocks = @([regex]::Matches($pem, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----') |
            ForEach-Object { $_.Value })
    if ($blocks.Count -eq 0) { throw "No certificates found in $bundle" }
    Write-Host "Found $($blocks.Count) certificate(s) in the bundle"

    $imported = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
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
        # Cleanup only, and the only action here allowed to fail quietly: the
        # temp file has already served its purpose and the import is asserted
        # below regardless. A leftover scratch file changes no outcome.
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        $found = Get-ChildItem "Cert:\LocalMachine\$store" |
            Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if (-not $found) {
            throw "$($cert.Subject) reported imported but is not present in LocalMachine\$store"
        }
        Write-Host "      verified present in LocalMachine\$store"
        $imported.Add($cert) | Out-Null
    }

    # Real gate: every imported certificate must now chain to a trusted root
    # using only the machine stores. This is the trust decision Schannel makes,
    # so a failure here means the template would not validate lab TLS either.
    foreach ($cert in $imported) {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        # No network in the build; revocation endpoints are not reachable.
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.ExtraStore.AddRange($imported)
        $ok = $chain.Build($cert)
        if (-not $ok) {
            $why = ($chain.ChainStatus | ForEach-Object { "$($_.Status): $($_.StatusInformation.Trim())" }) -join '; '
            throw "Chain validation FAILED for $($cert.Subject): $why"
        }
        Write-Host "Chain validation OK for $($cert.Subject) ($($chain.ChainElements.Count) element(s))"
    }
    Write-Host "Lab CA chain installed and validated"

    # Explicit success exit, INSIDE the try. Packer runs this as
    # `... ; exit $LastExitCode`, so falling off the end would hand the build's
    # verdict to whatever stale $LASTEXITCODE was left behind.
    # It must not live after the try/catch, or it would mask a caught failure.
    # `exit` still runs the finally below, so the transcript is closed.
    exit 0
}
catch {
    Write-Host ""
    Write-Host "Lab CA installation FAILED:"
    Write-Host ($PSItem.Exception.Message)
    Write-Host ""

    # Non-zero so the provisioner fails; the finally below still closes the
    # transcript. Never fall through to a success exit after a catch.
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
