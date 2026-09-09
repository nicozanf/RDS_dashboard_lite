param(
    [string]$DnsName = $env:COMPUTERNAME,
    [int]$Port = 443,
    [string]$AppId = '{f68d8d95-9bb1-4472-bf6b-f21454842174}',
    [string]$UrlAclUser = 'NT AUTHORITY\\SYSTEM',
    [string]$PreferredCertFriendlyName = '',
    [switch]$ForceNewCertificate
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this script as Administrator.'
}

$cert = $null
if (-not [string]::IsNullOrWhiteSpace($PreferredCertFriendlyName)) {
    if ($ForceNewCertificate) {
        throw 'ForceNewCertificate cannot be used with PreferredCertFriendlyName.'
    }

    $now = Get-Date
    $friendlyNameCert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.HasPrivateKey -and
            $_.NotAfter -gt $now -and
            $_.FriendlyName -eq $PreferredCertFriendlyName
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $friendlyNameCert) {
        throw "No valid certificate with FriendlyName '$PreferredCertFriendlyName' and private key was found in LocalMachine\\My."
    }

    $cert = $friendlyNameCert
    Write-Host "Using certificate by friendly name '$PreferredCertFriendlyName' thumbprint: $($cert.Thumbprint)"
}
else {
    if (-not $ForceNewCertificate) {
        $now = Get-Date
        $existingCert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.HasPrivateKey -and
                $_.NotAfter -gt $now -and
                ($_.DnsNameList.Unicode -contains $DnsName)
            } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1

        if ($existingCert) {
            $cert = $existingCert
            Write-Host "Reusing existing certificate thumbprint: $($cert.Thumbprint)"
        }
    }

    if (-not $cert) {
        $certParams = @{
            DnsName           = $DnsName
            CertStoreLocation = 'Cert:\LocalMachine\My'
            KeyAlgorithm      = 'RSA'
            KeyLength         = 2048
            HashAlgorithm     = 'SHA256'
            NotAfter          = (Get-Date).AddYears(3)
        }

        $cert = New-SelfSignedCertificate @certParams
        Write-Host "Created certificate thumbprint: $($cert.Thumbprint)"
    }
}

# Remove old binding if present, then bind new cert to 0.0.0.0:443.
netsh http delete sslcert ipport=0.0.0.0:$Port | Out-Null
netsh http add sslcert ipport=0.0.0.0:$Port certhash=$($cert.Thumbprint) appid=$AppId certstorename=MY | Out-Null

# URL ACL for HTTPS prefix ownership (needed for non-admin runtime contexts).
netsh http delete urlacl url=https://+:$Port/ | Out-Null
netsh http add urlacl url=https://+:$Port/ user="$UrlAclUser" | Out-Null

Write-Host "SSL certificate bound to 0.0.0.0:$Port"
Write-Host "URL ACL granted for https://+:$Port/ to $UrlAclUser"
Write-Host 'Ensure the certificate is trusted by clients (internal CA/GPO import if needed).'
