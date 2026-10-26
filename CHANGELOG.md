# Changelog

## 4.5.2 (loader 2.1.2)
- Loader now passes `window.__py316Meta` (version + changelog) before injecting, so About
  works without any in-page network request (Discord CSP blocks raw GitHub fetches).
- Payload normalized to pure ASCII / LF / no BOM to avoid encoding issues.

## 4.5.1
- Persistence fixed: Discord's renderer has no `localStorage`; prefs now use a cookie store.
- Settings and module toggles now actually persist across reloads.
- Replaced the broken "Reset token" with a "Reload client" button (auto re-inject).

## 4.5.0
- Vencord-style UX: native sidebar launcher button in the server bar.
- Settings tab: interface toggles + per-module on/off (RPC, Profile, Tools, Forge), persisted.
- About section with version/user, changelog from `version.json`, and Check-for-updates.
- Start-minimized, toast, and palette toggles.
- All settings stored in `py316-settings` and applied live.

## 4.4.2
- Mark-All-Read rewritten: enumerates channels via REST (`/users/@me/guilds`,
  `/guilds/{id}/channels`, `/users/@me/channels`) then dispatches `BULK_ACK_CHANNELS`.
- Clear success/warn logs with channel counts.

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
