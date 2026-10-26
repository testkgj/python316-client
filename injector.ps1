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
    [switch]$NoSelfUpdate,
    [switch]$NoMutex,
    [string]$StateDir,
    [switch]$Quiet
)

$LoaderVersion = '2.1.0'

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside param defaults when launched with -File.
if (-not $Root) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
}

# ---------------------------------------------------------------- state / log
$StateDir = if ($StateDir) { $StateDir } else { Join-Path $env:LOCALAPPDATA 'Python316' }
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
$AutoLaunch         = if ($null -ne $cfg.autoLaunch)      { [bool]$cfg.autoLaunch }      else { $true }
$RestartExisting    = if ($null -ne $cfg.restartExisting) { [bool]$cfg.restartExisting } else { $true }
$PollSeconds        = if ($cfg.pollSeconds)               { [int]$cfg.pollSeconds }      else { 6 }
$UpdateCheckSeconds = if ($cfg.updateCheckSeconds)        { [int]$cfg.updateCheckSeconds } else { 600 }
$HeartbeatMaxMs     = 30000

function Get-RepoBase {
    if ($RepoBase) { return $RepoBase.TrimEnd('/') }
    if ($MainUrl) { return ($MainUrl -replace '/[^/]+$', '').TrimEnd('/') }
    return $null
}
$RepoBase = Get-RepoBase

# ---------------------------------------------------------------- single instance
$mutex = $null
$hasMutex = $true
if (-not $NoMutex) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\Python316Injector')
    $hasMutex = $false
    try { $hasMutex = $mutex.WaitOne(0) } catch { $hasMutex = $true }
    if (-not $hasMutex) {
        Write-Log 'Another injector is already running. Exit.' 'WARN'
        exit 0
    }
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

function Get-ClientState {
    try {
        $r = Invoke-CdpEval -Code "try{JSON.stringify({v:(window.__python316&&window.__python316.__version)||null,a:(window.__python316&&window.__python316.__alive)||0,h:!!document.getElementById('py316-host')})}catch(e){null}"
        $s = Get-EvalValue -Text $r
        if (-not $s) { return $null }
        return ($s | ConvertFrom-Json)
    } catch { return $null }
}

function Test-PayloadCode {
    param([string]$Code)
    if (-not $Code -or $Code.Length -lt 500) { return $false }
    if ($Code -notmatch '__python316') { return $false }
    if ($Code -notmatch 'Python3\.16') { return $false }
    return $true
}

function Get-GitHubCoord {
    if ($RepoBase -and ($RepoBase -match 'raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)')) {
        return [pscustomobject]@{ Owner = $Matches[1]; Repo = $Matches[2]; Ref = $Matches[3] }
    }
    return $null
}

function Get-LatestSha {
    $coord = Get-GitHubCoord
    if (-not $coord) { return $null }
    try {
        $api = 'https://api.github.com/repos/{0}/{1}/commits/{2}?t={3}' -f $coord.Owner, $coord.Repo, $coord.Ref, [DateTime]::UtcNow.Ticks
        $r = Invoke-RestMethod -Uri $api -TimeoutSec 10 -UseBasicParsing -Headers @{ 'User-Agent' = 'Python316' }
        if ($r.sha) { return [string]$r.sha }
    } catch { Write-Log "commit lookup failed: $($_.Exception.Message)" 'WARN' }
    return $null
}

function Get-RemoteVersionJson {
    # Prefer a commit-pinned URL (immutable, never CDN-stale), fall back to raw.
    $coord = Get-GitHubCoord
    $sha = Get-LatestSha
    $urls = @()
    if ($coord -and $sha) {
        $urls += ('https://raw.githubusercontent.com/{0}/{1}/{2}/version.json' -f $coord.Owner, $coord.Repo, $sha)
    }
    if ($RepoBase) {
        $urls += ('{0}/version.json?t={1}' -f $RepoBase, [DateTime]::UtcNow.Ticks)
    }
    foreach ($u in $urls) {
        try {
            $txt = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15).Content
            if ($txt -is [byte[]]) { $txt = [System.Text.Encoding]::UTF8.GetString($txt) }
            $txt = ([string]$txt).TrimStart([char]0xFEFF)
            $j = $txt | ConvertFrom-Json
            if ($j.version) {
                return [pscustomobject]@{
                    Version      = [string]$j.version
                    Url          = [string]$j.url
                    Sha256       = [string]$j.sha256
                    LoaderVersion= [string]$j.loaderVersion
                    LoaderUrl    = [string]$j.loaderUrl
                    LoaderSha256 = [string]$j.loaderSha256
                    Sha          = $sha
                    Coord        = $coord
                }
            }
        } catch {}
    }
    return $null
}

function Get-RemotePayload {
    param($Meta)
    if ($NoDownload) { return $null }
    if (-not $Meta) { $Meta = Get-RemoteVersionJson }
    $version = if ($Meta) { $Meta.Version } else { $null }
    $coord = if ($Meta) { $Meta.Coord } else { Get-GitHubCoord }
    $sha = if ($Meta) { $Meta.Sha } else { $null }

    $url = $null
    if ($coord -and $sha) {
        $url = 'https://raw.githubusercontent.com/{0}/{1}/{2}/main.js' -f $coord.Owner, $coord.Repo, $sha
    } elseif ($Meta -and $Meta.Url) {
        $url = $Meta.Url
    } elseif ($MainUrl) {
        $url = $MainUrl
    }
    if (-not $url) { Write-Log 'No payload URL resolved' 'WARN'; return $null }

    $tmp = Join-Path $env:TEMP ('py316-payload-{0}.js' -f [guid]::NewGuid().ToString('N'))
    try {
        $sep = if ($url -match '\?') { '&' } else { '?' }
        $fUrl = '{0}{1}t={2}' -f $url, $sep, [DateTime]::UtcNow.Ticks
        Invoke-WebRequest -Uri $fUrl -UseBasicParsing -TimeoutSec 25 -OutFile $tmp
        if ($Meta -and $Meta.Sha256) {
            $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
            if ($h -ne ([string]$Meta.Sha256).ToLower()) { throw 'payload sha256 mismatch' }
        }
        $code = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if (-not (Test-PayloadCode -Code $code)) { throw 'payload failed validation' }
        if ($version) {
            if ($code -match '__version\s*=\s*[''"]([^''"]+)[''"]') {
                $codeVer = $Matches[1]
                if ($codeVer -ne $version) { throw "payload version mismatch (declared=$version got=$codeVer)" }
                $version = $codeVer
            } else {
                throw "payload missing version marker (declared=$version)"
            }
        } else {
            if ($code -match '__version\s*=\s*[''"]([^''"]+)[''"]') { $version = $Matches[1] }
        }
        Move-Item -LiteralPath $tmp -Destination $MainPath -Force
        return [pscustomobject]@{ Code = $code; Version = $version; Url = $url }
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" 'WARN'
        return $null
    } finally {
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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
    param($Meta)
    $p = Get-RemotePayload -Meta $Meta
    if ($p) { return $p }
    $p = Get-LocalPayload
    if ($p) {
        Write-Log "Using local payload: $MainPath"
        return $p
    }
    throw 'No payload available (download failed and no valid local main.js)'
}

function Update-LoaderIfNeeded {
    param($Meta)
    if ($NoSelfUpdate -or -not $Meta) { return }
    $lv = [string]$Meta.LoaderVersion
    if (-not $lv -or $lv -eq $LoaderVersion) { return }
    if (-not $Meta.LoaderUrl) { Write-Log 'loader update available but no loaderUrl' 'WARN'; return }
    Write-Log ("Loader update {0} -> {1}" -f $LoaderVersion, $lv)
    $tmp = Join-Path $env:TEMP ('py316-loader-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
    try {
        $sep = if ($Meta.LoaderUrl -match '\?') { '&' } else { '?' }
        Invoke-WebRequest -Uri ('{0}{1}t={2}' -f $Meta.LoaderUrl, $sep, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 25 -OutFile $tmp
        if ($Meta.LoaderSha256) {
            $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
            if ($h -ne ([string]$Meta.LoaderSha256).ToLower()) { throw 'loader sha256 mismatch' }
        }
        $null = [scriptblock]::Create([System.IO.File]::ReadAllText($tmp))
        Copy-Item -LiteralPath $tmp -Destination (Join-Path $Root 'injector.ps1') -Force
        $script:PendingReload = $true
        Write-Log 'Loader updated; scheduling reload' 'OK'
    } catch {
        Write-Log "Loader update failed: $($_.Exception.Message)" 'WARN'
    } finally {
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
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
$script:CachedPayload = $null
$script:LastCheck = 0
$script:PendingReload = $false

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
        $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $needNet = (-not $script:CachedPayload) -or (($epoch - $script:LastCheck) -ge $UpdateCheckSeconds)
        $meta = $null
        if ($needNet) {
            $meta = Get-RemoteVersionJson
            Update-LoaderIfNeeded -Meta $meta
            $script:CachedPayload = Get-Payload -Meta $meta
            $script:LastCheck = $epoch
        }
        $payload = $script:CachedPayload
        if (-not $payload) { throw 'No payload available' }

        $state = Get-ClientState
        $current = if ($state) { [string]$state.v } else { $null }

        if ($payload.Version) {
            if ($current -eq [string]$payload.Version) {
                $alive = $false
                if ($state -and $state.a) {
                    try { $alive = (([double]$epoch * 1000) - [double]$state.a) -lt $HeartbeatMaxMs } catch { $alive = $false }
                }
                if ($alive -and $state.h) {
                    if ($script:LastOkVersion -ne $current) { Write-Log ("Up to date (v{0})" -f $current) 'DEBUG'; $script:LastOkVersion = $current }
                    $script:FailBackoff = 0
                    return
                }
                Write-Log 'Client heartbeat stale/missing, re-injecting' 'WARN'
            }
        } elseif ($current) {
            $script:FailBackoff = 0
            return
        }

        if ($RepoBase) {
            $safeBase = $RepoBase -replace "'", "''"
            [void](Invoke-CdpEval -Code ("window.__py316Repo = '{0}';" -f $safeBase))
        }

        [void](Invoke-CdpEval -Code $payload.Code)
        Start-Sleep -Milliseconds 250
        $after = Get-ClientState

        if ($after -and $after.v) {
            $script:FailBackoff = 0
            $script:LastOkVersion = [string]$after.v
            Save-InjectState -Version ([string]$after.v)
            if ($payload.Version -and ([string]$after.v -ne [string]$payload.Version)) {
                Write-Log ("Injected but version mismatch (current={0} payload={1})" -f $after.v, $payload.Version) 'WARN'
            } else {
                Write-Log ("main.js injected successfully (v{0})" -f $after.v) 'OK'
            }
        } elseif ($after -and $after.h) {
            $script:FailBackoff = 0
            Write-Log 'main.js injected (legacy payload, no version)' 'OK'
        } else {
            throw 'marker missing after evaluate (page may not be ready)'
        }
    } catch {
        $script:FailBackoff = if ($script:FailBackoff -lt 6) { 6 } else { [Math]::Min(60, $script:FailBackoff * 2) }
        Write-Log ("Injection error: {0} (backoff {1}s)" -f $_.Exception.Message, $script:FailBackoff) 'ERR'
    }
}

# ---------------------------------------------------------------- run
Write-Log ("Python316 injector v{0} starting (port={1} root={2} once={3} base={4})" -f $LoaderVersion, $Port, $Root, [bool]$Once, $RepoBase)

try {
    if ($Once) {
        Invoke-Pass
    } else {
        while ($true) {
            try { Invoke-Pass } catch { Write-Log "Pass error: $($_.Exception.Message)" 'ERR' }
            if ($script:PendingReload) {
                Write-Log 'Reloading watcher with the new loader'
                try { if ($mutex -and $hasMutex) { $mutex.ReleaseMutex(); $hasMutex = $false } } catch {}
                $null = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                    '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f (Join-Path $Root 'injector.ps1'))
                ) -WindowStyle Hidden -PassThru
                break
            }
            $sleep = [Math]::Max($PollSeconds, $script:FailBackoff)
            Start-Sleep -Seconds $sleep
        }
    }
} finally {
    try { if ($mutex -and $hasMutex) { $mutex.ReleaseMutex() } } catch {}
    try { if ($mutex) { $mutex.Dispose() } } catch {}
}
