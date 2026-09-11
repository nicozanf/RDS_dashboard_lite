# RDS Dashboard Lite Configuration

Copy `webapp/config-example.toml` to `webapp/config.toml`. The local configuration file is intentionally excluded from publication.

## Example

```toml
Title = "RDS Dashboard"
CollectorTimeoutSeconds = 90
CycleDelaySeconds = 20
MaxConcurrentJobs = 6
CollectCpuRam = true
CustomLoginDomain = "example.com"

[Farms]
Default = ["rds01.example.com", "rds02.example.com"]
```

## Settings

- `Title`: browser and dashboard title.
- `CollectorTimeoutSeconds`: maximum duration of one collection cycle. The tracked example uses `90` seconds for larger server lists.
- `CycleDelaySeconds`: delay after a collection cycle completes. The tracked example uses `20` seconds.
- `MaxConcurrentJobs`: maximum simultaneous server probes. Lower values reduce CPU, memory, and remote connection pressure. Default: `6`.
- `CollectCpuRam`: controls remote CPU and RAM CIM probes. Set to `false` to reduce collector and RDS host load; session collection through `quser` continues. Default: `true`.
- `CollectorDebugMode`: enables console diagnostics when `true`.
- `CustomLoginDomain`: optional AD domain used by the login form.
- `[Farms]` / `Default`: configured RDS hosts for the single dashboard farm. Keep this as one farm because farm selection is not available in the dashboard.

## Authentication

The server detects the joined AD domain unless `CustomLoginDomain` is set. Authorized users must belong to the local `RDS-Dashboard-Admins` group.

## Runtime data

The collector keeps only the latest live snapshot in synchronized server memory. No SQLite database, snapshot file, history store, application log, or audit log is created.

Configuration is file-managed. There is no Settings page or configuration write API.
