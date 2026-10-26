[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$Tests   = $PSScriptRoot
$Root    = Split-Path -Parent $Tests
$Injector = Join-Path $Root 'injector.ps1'
$script:Fails = 0

function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Fails++ }
function Check($cond, $m) { if ($cond) { Pass $m } else { Fail $m } }
function WriteJson($path, $obj) {
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
function WaitUrl($u, $sec = 12) {
    for ($i = 0; $i -lt ($sec * 2); $i++) {
        try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 1 | Out-Null; return $true } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

Write-Host '=== Python3.16 test suite ===' -ForegroundColor Cyan

# ---- static checks
node --check (Join-Path $Root 'main.js') *> $null
Check ($LASTEXITCODE -eq 0) 'main.js parses'
foreach ($f in 'injector.ps1','install.ps1','uninstall.ps1','deploy.ps1','doctor.ps1') {
    try { $null = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $Root $f))); Pass "$f parses" }
    catch { Fail "$f parse: $($_.Exception.Message)" }
}

$ver = [regex]::Match((Get-Content (Join-Path $Root 'main.js') -Raw), "const __version = '([^']+)'").Groups[1].Value
$loaderVer = [regex]::Match((Get-Content $Injector -Raw), "LoaderVersion\s*=\s*'([^']+)'").Groups[1].Value
Check ([bool]$ver) "payload version detected ($ver)"
Check ([bool]$loaderVer) "loader version detected ($loaderVer)"

# ---- deps
Push-Location $Tests
if (-not (Test-Path (Join-Path $Tests 'node_modules\ws'))) {
    Write-Host '  installing test deps (ws)...' -ForegroundColor DarkGray
    npm install --silent *> $null
}
Pop-Location
Check (Test-Path (Join-Path $Tests 'node_modules\ws')) 'ws test dependency available'

$work = Join-Path $env:TEMP ('py316-tests-' + [guid]::NewGuid().ToString('N'))
$served = Join-Path $work 'served'
$bad = Join-Path $work 'served-bad'
New-Item -ItemType Directory -Path $served -Force | Out-Null
New-Item -ItemType Directory -Path $bad -Force | Out-Null
Copy-Item (Join-Path $Root 'main.js') (Join-Path $served 'main.js')
Copy-Item (Join-Path $Root 'main.js') (Join-Path $bad 'main.js')

$shaMain = (Get-FileHash (Join-Path $served 'main.js') -Algorithm SHA256).Hash.ToLower()
WriteJson (Join-Path $served 'version.json') ([ordered]@{
    version = $ver; url = 'http://127.0.0.1:19400/main.js'; sha256 = $shaMain
    loaderVersion = $loaderVer; changelog = 'test'
})
WriteJson (Join-Path $bad 'version.json') ([ordered]@{
    version = $ver; url = 'http://127.0.0.1:19402/main.js'; sha256 = ('0' * 64)
    loaderVersion = $loaderVer; changelog = 'bad sha'
})

$serve1 = Start-Process node -ArgumentList (Join-Path $Tests 'serve.js'), $served, '19400' -PassThru -WindowStyle Hidden
$serve2 = Start-Process node -ArgumentList (Join-Path $Tests 'serve.js'), $bad, '19402' -PassThru -WindowStyle Hidden
$mock   = Start-Process node -ArgumentList (Join-Path $Tests 'mock-cdp.js'), '19401' -PassThru -WindowStyle Hidden

try {
    Check (WaitUrl 'http://127.0.0.1:19400/version.json') 'static server up'
    Check (WaitUrl 'http://127.0.0.1:19401/json') 'mock CDP up'

    # ---- test 1: happy path + up-to-date
    $root1 = Join-Path $work 'root1'; New-Item -ItemType Directory -Path $root1 -Force | Out-Null
    $state1 = Join-Path $work 'state1'
    $main1 = Join-Path $root1 'main.js'
    $argv = @('-Root', $root1, '-MainPath', $main1, '-StateDir', $state1, '-Port', '19401',
              '-RepoBase', 'http://127.0.0.1:19400', '-Once', '-NoMutex', '-NoLaunch', '-NoRestart', '-NoSelfUpdate')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Injector @argv *> $null
    $log1 = Get-Content (Join-Path $state1 'injector.log') -Raw -ErrorAction SilentlyContinue
    Check ($log1 -match 'injected successfully') 'happy: payload injected'
    Check (Test-Path $main1) 'happy: cache written'

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Injector @argv *> $null
    $log1b = Get-Content (Join-Path $state1 'injector.log') -Raw -ErrorAction SilentlyContinue
    Check ($log1b -match 'Up to date') 'happy: second pass up to date'

    # ---- test 2: sha256 mismatch rejected
    $root2 = Join-Path $work 'root2'; New-Item -ItemType Directory -Path $root2 -Force | Out-Null
    $state2 = Join-Path $work 'state2'
    $argv2 = @('-Root', $root2, '-MainPath', (Join-Path $root2 'main.js'), '-StateDir', $state2, '-Port', '19401',
               '-RepoBase', 'http://127.0.0.1:19402', '-Once', '-NoMutex', '-NoLaunch', '-NoRestart', '-NoSelfUpdate')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Injector @argv2 *> $null
    $log2 = Get-Content (Join-Path $state2 'injector.log') -Raw -ErrorAction SilentlyContinue
    Check ($log2 -match 'sha256 mismatch|No payload available') 'integrity: bad sha256 rejected'
    Check (-not (Test-Path (Join-Path $root2 'main.js'))) 'integrity: no cache written for bad payload'

    # ---- test 3: loader self-update
    $nextLoader = Join-Path $served 'loader-next.ps1'
    [IO.File]::WriteAllText($nextLoader, "param()`r`n# NEXT-LOADER`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $nextSha = (Get-FileHash $nextLoader -Algorithm SHA256).Hash.ToLower()
    WriteJson (Join-Path $served 'version.json') ([ordered]@{
        version = $ver; url = 'http://127.0.0.1:19400/main.js'; sha256 = $shaMain
        loaderVersion = '9.9.9'; loaderUrl = 'http://127.0.0.1:19400/loader-next.ps1'
        loaderSha256 = $nextSha; changelog = 'loader update test'
    })
    $root3 = Join-Path $work 'root3'; New-Item -ItemType Directory -Path $root3 -Force | Out-Null
    Copy-Item $Injector (Join-Path $root3 'injector.ps1')
    $state3 = Join-Path $work 'state3'
    $argv3 = @('-Root', $root3, '-MainPath', (Join-Path $root3 'main.js'), '-StateDir', $state3, '-Port', '19401',
               '-RepoBase', 'http://127.0.0.1:19400', '-Once', '-NoMutex', '-NoLaunch', '-NoRestart')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Injector @argv3 *> $null
    $log3 = Get-Content (Join-Path $state3 'injector.log') -Raw -ErrorAction SilentlyContinue
    $updated = (Get-Content (Join-Path $root3 'injector.ps1') -Raw -ErrorAction SilentlyContinue)
    Check ($log3 -match 'Loader update') 'self-update: detected'
    Check ($updated -match 'NEXT-LOADER') 'self-update: loader file replaced'
}
finally {
    foreach ($p in $serve1, $serve2, $mock) { if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} } }
    if (-not $Keep) { try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}

Write-Host ''
if ($script:Fails -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Fails) TEST(S) FAILED" -ForegroundColor Red
    exit 1
}
