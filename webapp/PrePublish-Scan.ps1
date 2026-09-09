param(
    # Root directory to scan. Defaults to this script's directory.
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = 'Stop'

# File types that are likely to contain config/code/docs with sensitive values.
$include = @('*.ps1','*.psm1','*.toml','*.md','*.cmd','*.html','*.js','*.css')

# Known large/generated/runtime folders intentionally excluded from scanning.
$excludeDirs = @('.git','runtime','logs','sqlite-tools-win-x64-3530000')

# Rules are designed for fast prepublish checks, not deep secret scanning.
$patterns = @(
    # Internal network/domain suffixes.
    @{ Name='InternalDomain'; Regex='(?i)\b(?![a-z0-9.-]*(?:example|domain)\.local\b)[a-z0-9.-]+\.(local|corp|lan)\b' },
    # Internal naming tokens split to avoid self-matching simple repo sweeps.
    @{ Name='InternalHostPrefix'; Regex=('(?i)\b(' + 'per' + 'ed|se' + 'red|gpa' + 'prod|nexi' + 'red' + ')\b') },
    # Private key material should never be committed.
    @{ Name='PrivateKeyBlock'; Regex='-----BEGIN (RSA |EC )?PRIVATE KEY-----' },
    # Basic assignment patterns for credentials/secrets.
    @{ Name='PasswordAssign'; Regex='(?i)\b(password|pwd|secret|token|apikey)\b\s*[:=]\s*["''][^"'']+["'']' },
    # Bearer-like tokens embedded in text/files.
    @{ Name='BearerToken'; Regex='(?i)\bbearer\s+[a-z0-9\-_\.=]{16,}\b' }
)

# Build the scan file list and drop files under excluded directories.
$files = Get-ChildItem -Path $Root -Recurse -File -Include $include | Where-Object {
    $full = $_.FullName
    foreach ($d in $excludeDirs) {
        if ($full -match [regex]::Escape([IO.Path]::DirectorySeparatorChar + $d + [IO.Path]::DirectorySeparatorChar)) { return $false }
    }
    return $true
}

$hits = @()
foreach ($f in $files) {
    $i = 0
    # Scan line-by-line so we can report precise line numbers for triage.
    foreach ($line in Get-Content -Path $f.FullName) {
        $i++
        foreach ($p in $patterns) {
            if ($line -match $p.Regex) {
                $hits += [pscustomobject]@{
                    Rule = $p.Name
                    File = $f.FullName
                    Line = $i
                    Text = $line.Trim()
                }
            }
        }
    }
}

if ($hits.Count -gt 0) {
    # Non-zero exit code makes this script CI/prepublish friendly.
    Write-Host "Prepublish scan failed. Potential sensitive content found:" -ForegroundColor Red
    $hits | Select-Object Rule, File, Line, Text | Format-Table -AutoSize
    exit 1
}

Write-Host "Prepublish scan passed." -ForegroundColor Green
exit 0