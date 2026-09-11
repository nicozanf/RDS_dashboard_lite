# RDS Dashboard Lite Installation

## Prerequisites

- Windows Server joined to the AD domain.
- Windows PowerShell 5.1 or later.
- Configured RDS hosts reachable with `quser`, `logoff`, `tsdiscon`, and `msg`.
- An HTTPS certificate with a private key in `Cert:\LocalMachine\My`.
- Administrative rights for certificate binding, URL ACL, and service installation.
- NSSM available offline for Windows Service installation.

SQLite, a database server, and application log directories are not required.

## Configure

1. Copy `webapp/config-example.toml` to `webapp/config.toml`.
2. Set the dashboard title and RDS hosts under `[Farms]` in the `Default` list.
3. Set `CustomLoginDomain` when the login domain cannot be detected automatically.
4. Add authorized users to the local `RDS-Dashboard-Admins` group.

## HTTPS

Run PowerShell as Administrator and use `webapp/setup_https_443.ps1` to create or select the certificate and configure the SSL binding and URL ACL for port 443.

Verify:

```powershell
netsh http show sslcert ipport=0.0.0.0:443
netsh http show urlacl url=https://+:443/
```

## Foreground test

Run `webapp/run_webapp.cmd`, then open `https://server-name/`. Authenticate with an AD account in `RDS-Dashboard-Admins`.

The retained routes are `/login`, `/dashboard`, `/help`, `/api/data`, and `/api/session-action`.

## Windows Service

Run `webapp/install_service.ps1` as Administrator. Configure the service identity as an account that can query and control the configured RDS hosts. The script configures automatic startup and restart recovery through NSSM.

Verify:

```powershell
Get-Service RDSDashboardWeb
nssm status RDSDashboardWeb
```

## Validation

Run the focused authenticated smoke test:

```powershell
.\webapp\Test-HealthEndpoints.ps1 -BaseUrl "https://server-name" -Credential (Get-Credential)
```

Confirm that no SQLite database or `logs` directory is created under `webapp` during startup and collection.
