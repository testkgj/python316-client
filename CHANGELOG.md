# Changelog

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
