[CmdletBinding()]
param(
    [string]$Root,
    [int]$Port
)

$ErrorActionPreference = 'Continue'
if (-not $Root) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
}

$StateDir = Join-Path $env:LOCALAPPDATA 'Python316'
function Line($k, $v, $c = 'Gray') {
    Write-Host ('  {0,-22} {1}' -f $k, $v) -ForegroundColor $c
}
function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }

Write-Host '===================================================' -ForegroundColor Cyan
Write-Host '   Python3.16 - Doctor' -ForegroundColor Cyan
Write-Host '===================================================' -ForegroundColor Cyan

# config
$cfg = $null
$configPath = Join-Path $Root 'config.json'
if (-not (Test-Path $configPath)) { $configPath = Join-Path $StateDir 'config.json' }
if (Test-Path $configPath) {
    try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch {}
}
if (-not $PSBoundParameters.ContainsKey('Port')) {
    if ($cfg -and $cfg.port) { $Port = [int]$cfg.port } else { $Port = 9222 }
}
Line 'config' $configPath
if ($cfg) {
    Line 'port' $Port
    Line 'payload url' $cfg.githubRaw
    Line 'autoLaunch' $cfg.autoLaunch
    Line 'restartExisting' $cfg.restartExisting
} else {
    Warn 'config.json not found'
}

# install dir
Write-Host '-- install --' -ForegroundColor Cyan
foreach ($f in 'injector.ps1','main.js','config.json') {
    $p = Join-Path $StateDir $f
    if (Test-Path $p) { Line $f ("{0} bytes" -f (Get-Item $p).Length) } else { Line $f 'MISSING' 'Red' }
}
$localVer = $null
$mp = Join-Path $StateDir 'main.js'
if (Test-Path $mp) {
    $c = Get-Content $mp -Raw
    if ($c -match '__version\s*=\s*[''"]([^''"]+)[''"]') { $localVer = $Matches[1] }
    Line 'cached payload ver' $localVer
}

# task
Write-Host '-- scheduled task --' -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName 'Python316 Injector' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'Python316 Injector'
    Line 'state' $task.State 'Green'
    Line 'last result' $info.LastTaskResult $(if ($info.LastTaskResult -eq 0) {'Green'} else {'Yellow'})
    Line 'last run' $info.LastRunTime
} else {
    Bad 'task not registered'
}
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Python316.vbs'
Line 'startup fallback' $(if (Test-Path $startup) { 'present' } else { 'not used' })

# discord
Write-Host '-- Discord --' -ForegroundColor Cyan
$procs = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
Line 'processes' $procs.Count $(if ($procs.Count -gt 0) {'Green'} else {'Yellow'})
if ($procs.Count -gt 0) { Line 'exe' $procs[0].Path }

# debug port + injection
Write-Host '-- injection --' -ForegroundColor Cyan
$targets = $null
try { $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json" -f $Port) -TimeoutSec 3 -UseBasicParsing } catch {}
if (-not $targets) {
    Bad "debug port $Port not reachable (Discord not started by the loader?)"
} else {
    Ok "debug port $Port reachable"
    $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl } | Where-Object { $_.url -match 'discord' -or $_.title -match 'Discord' } | Select-Object -First 1)
    if (-not $page) { $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl } | Select-Object -First 1) }
    if ($page) {
        Line 'target' $page.url
        try {
            $ws = New-Object System.Net.WebSockets.ClientWebSocket
            $ct = [System.Threading.CancellationToken]::None
            [void]$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).GetAwaiter().GetResult()
            $expr = "JSON.stringify({v:(window.__python316&&window.__python316.__version)||null,host:!!document.getElementById('py316-host')})"
            $msg = @{ id=1; method='Runtime.evaluate'; params=@{ expression=$expr; returnByValue=$true } } | ConvertTo-Json -Depth 6 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
            [void]$ws.SendAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult()
            $ms = New-Object System.IO.MemoryStream; $buf = New-Object byte[] 16384
            while ($true) {
                $r = $ws.ReceiveAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buf)), $ct).GetAwaiter().GetResult()
                if ($r.Count -gt 0) { $ms.Write($buf,0,$r.Count) }
                if ($r.EndOfMessage) { break }
            }
            $resp = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            try { [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'x',$ct).GetAwaiter().GetResult() } catch {}
            $o = $resp | ConvertFrom-Json
            $val = $o.result.result.value
            if ($val) {
                $j = $val | ConvertFrom-Json
                if ($j.v) { Ok "injected client v$($j.v)" } else { Warn 'client object present but no version (older payload)' }
                if ($j.host) { Ok 'UI host present' } else { Bad 'UI host missing' }
                if ($localVer -and $j.v -and ($localVer -ne $j.v)) { Warn "cached=$localVer live=$($j.v) (will update on next pass)" }
            } else {
                Bad 'marker missing (not injected)'
            }
        } catch {
            Bad "CDP eval failed: $($_.Exception.Message)"
        }
    }
}

# log
Write-Host '-- log tail --' -ForegroundColor Cyan
$log = Join-Path $StateDir 'injector.log'
if (Test-Path $log) { Get-Content $log -Tail 12 } else { Warn 'no log yet' }

Write-Host ''
Write-Host 'Doctor finished.' -ForegroundColor Cyan
