# Changelog

## 4.4.1 (loader 2.1.1)
- Fixed CDP target selection: never target the Discord Overlay (`/popout`); prefer
  `/channels/` then `/app`. This was causing flaky/absent injection.
- Mark-All-Read: scans channel stores properly, collects real channel ids, clearer logs.
- Command palette: `Run self-test` (gateway, REST, auth, token, webpack).

## 4.4.0 (loader 2.1.0)
- SHA-256 integrity verification for payload and loader (hash must match `version.json`).
- Loader self-update: watches `loaderVersion`, downloads, verifies, parse-checks, swaps itself, reloads.
- Heartbeat watchdog: payload posts `__alive`; the loader re-injects if the client dies or goes stale.
- Command palette (`Ctrl+Shift+K`): apply/stop RPC, ghost, mark read, forges, copy token/diagnostics.
- Forge progress bars + cancel buttons.
- Automated test suite (`tests/run-tests.ps1`) + CI: happy path, up-to-date, bad-hash reject, self-update.
- API + commit-SHA pinned discovery (CDN-stale proof).

## 4.3.0
- Loader v2: reads `version.json`, validates payload, atomic cache, exponential backoff.
- Hot updates: re-injects in-place when the remote version changes (no Discord restart).
- `doctor.ps1`: full self-diagnosis (install, task, port, target, live marker, logs).
- `install.ps1`: `-Status`, `-Repair`, `-Uninstall`, script validation, version display.
- Client: version marker, jittered RPC rotation, toasts, `Ctrl+Shift+P` toggle, Escape to tray,
  footer status, update badge via `version.json`.
- CI: syntax validation workflow.
- Docs + `.gitattributes`.

## 4.2.0
- Auto-loader + headless CDP injection at Discord launch.
- Scheduled task at logon, GitHub raw payload, GitHub repo setup.

## 4.1.0
- Legacy `payload.js` (native sidebar + modal).

## 4.0.0
- Initial Python3.16 client payload.
