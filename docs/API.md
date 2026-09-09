# RDS Dashboard Lite API

The service listens over HTTPS on port 443. All application routes require an authenticated AD user in the local `RDS-Dashboard-Admins` group unless noted otherwise.

## Pages

- `GET /login`: AD form login.
- `GET /dashboard`: live current-session dashboard.
- `GET /help`: help page.
- `GET /logout`: clears the authenticated session.

## Live data

`GET /api/data` returns the latest collector snapshot. The response contains `GeneratedAtUtc`, `Summary`, `Servers`, and `Sessions`. Before the first collection cycle it returns an empty snapshot with a loading message.

The collector publishes the latest payload into synchronized memory owned by the HTTPS server. No snapshot file, SQLite database, or historical data store is used.

## Session actions

`POST /api/session-action` accepts an authenticated, CSRF-protected form body:

- `action`: `disconnect`, `logoff`, or `sendmsg`
- `server`: configured RDS server name
- `id`: numeric session ID
- `message`: required for `sendmsg`
- `username` and `sessionName`: optional display context
- `csrfToken`: token rendered into the dashboard

The server invokes the native `tsdiscon`, `logoff`, or `msg` command. Invalid server names, session IDs, missing messages, unauthenticated requests, and invalid CSRF tokens are rejected.

## Security

Authentication uses AD credentials through the server's domain context. Sessions use the `RDSAUTH` cookie and expire according to the configured session timeout. Session actions require both authentication and CSRF validation.

Removed routes for status, health, logs, settings, farm, host, AD search, RDP login history, and historical metrics return HTTP 404.
