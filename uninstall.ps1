[CmdletBinding()]
param(
    [switch]$KeepFiles
)

$ErrorActionPreference = 'SilentlyContinue'
$TaskName = 'Python316 Injector'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Python316'

Write-Host '== Python3.16 uninstall ==' -ForegroundColor Cyan

# stop watcher
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
    if ($_.CommandLine -and $_.CommandLine -match 'Python316' -and $_.CommandLine -match 'injector\.ps1') {
        try { Stop-Process -Id $_.ProcessId -Force } catch {}
    }
}

# scheduled task
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host "Removed scheduled task: $TaskName"
} catch {
    Write-Host "Scheduled task not present."
}

# startup fallback
$StartupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'Python316.vbs'
if (Test-Path $StartupVbs) {
    Remove-Item $StartupVbs -Force
    Write-Host 'Removed startup entry.'
}

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
}

Write-Host 'Done. Restart Discord to detach.' -ForegroundColor Green
