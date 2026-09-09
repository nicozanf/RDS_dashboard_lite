# AGENTS.md

## RDS Dashboard Web App — AI Coding Agent Instructions

This project is deployed in an **isolated server environment**. The following conventions and constraints are critical for AI coding agents working in this codebase:

### Key Environment Constraints
- **No internet access**: All dependencies must be available offline. Do not attempt to download modules or packages at runtime or during setup.
- **Windows Server only**: Scripts and services are designed for Windows Server with PowerShell 5.1+.
- **Active Directory domain join required**: Authentication and session management depend on AD.
- **Service runs as Windows Service**: Use `nssm.exe` for service management; must be present locally.
- **In-memory live data only**: the collector publishes the latest snapshot into synchronized memory owned by `server.ps1`; no database or snapshot file is required.
- **Collector runspace**: collection runs in a server-owned background runspace and may recreate automatically after failure.

### Project Structure
- `webapp/server.ps1`: Main HTTPS web server, authentication, UI, and API endpoints.
- `webapp/collector.ps1`: Background collector for live RDS sessions and optional server metrics.
- `webapp/setup_https_443.ps1`: Certificate and SSL binding setup.
- `webapp/install_service.ps1`: Service install/management.
- `webapp/runtime/`: Reserved runtime directory; live data is held in memory and application log files are disabled.

### Coding and Automation Conventions
- **Do not add external dependencies** unless they are already present in the repo or explicitly provided offline.
- **All scripts must run with local resources only**.
- **No cloud APIs or SaaS integrations**.
- **All authentication is AD-based**; do not modify to support other auth methods without explicit instruction.
- **Shadowing is intentionally unsupported in web mode**.
- **Cycle-based data collection**: Do not change polling to fixed intervals.

### Security and Access
- **Restrict access** to internal admin networks only.
- **Do not expose endpoints or credentials**.
- **Service accounts should have minimum required privileges**.

### Documentation
- For installation and validation, see [INSTALL.md](INSTALL.md).
- For deployment settings, certificates, and service identities, see [CONFIG.md](CONFIG.md).
- For authentication behavior, API reference, and firewall requirements, see [API.md](API.md).
- Do not duplicate documentation; link to it instead.

---

This file helps AI coding agents understand the isolated, offline, and security-focused nature of this deployment. Update this file if deployment constraints or conventions change.
