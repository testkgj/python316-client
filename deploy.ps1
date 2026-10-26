[CmdletBinding()]
param(
    [string]$Repo = 'python316-client',
    [string]$Branch = 'main',
    [string]$Message = 'Update Python3.16 client'
)

$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $PSScriptRoot

$login = (gh api user -q .login).Trim()
if (-not $login) { throw 'gh is not authenticated. Run: gh auth login' }
$full = "$login/$Repo"

Write-Host "== Deploying to GitHub: $full ==" -ForegroundColor Cyan

git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { git init -b $Branch | Out-Null }

$url = "https://github.com/$full.git"
$remote = (git remote) 2>$null
if ($remote -notcontains 'origin') {
    git remote add origin $url | Out-Null
} else {
    git remote set-url origin $url | Out-Null
}

gh repo view $full *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating repo $full"
    gh repo create $full --public --source=. --remote=origin --push=false
}

git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -m $Message | Out-Null
} else {
    Write-Host 'Nothing to commit.' -ForegroundColor Yellow
}

# Compute normalized (LF, no BOM) SHA-256 so hashes match what raw.githubusercontent
# serves for the committed blob regardless of the local working-tree line endings.
function Get-NormalizedSha256([string]$Path) {
    $raw = [IO.File]::ReadAllBytes((Join-Path $PWD $Path))
    $t = [Text.Encoding]::UTF8.GetString($raw)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    $t = $t.Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLower()
}

$loaderVersion = ''
if (Test-Path 'injector.ps1') {
    $m = [regex]::Match((Get-Content 'injector.ps1' -Raw), "LoaderVersion\s*=\s*'([^']+)'")
    if ($m.Success) { $loaderVersion = $m.Groups[1].Value }
}

# Pin version.json to the exact commit so raw.githubusercontent.com CDN caching
# can never serve an older payload than the version it advertises.
$codeSha = (git rev-parse HEAD).Trim()
if (Test-Path 'version.json') {
    $v = Get-Content 'version.json' -Raw | ConvertFrom-Json
    $mainSha = Get-NormalizedSha256 'main.js'
    $loaderSha = Get-NormalizedSha256 'injector.ps1'
    $pinned = "https://raw.githubusercontent.com/$full/$codeSha/main.js"
    $pinnedLoader = "https://raw.githubusercontent.com/$full/$codeSha/injector.ps1"
    $changed = ([string]$v.url -ne $pinned) -or
               ([string]$v.sha256 -ne $mainSha) -or
               ([string]$v.loaderVersion -ne $loaderVersion) -or
               ([string]$v.loaderSha256 -ne $loaderSha)
    if ($changed) {
        $o = [ordered]@{
            version       = [string]$v.version
            url           = $pinned
            sha256        = $mainSha
            loaderVersion = $loaderVersion
            loaderUrl     = $pinnedLoader
            loaderSha256  = $loaderSha
            changelog     = [string]$v.changelog
        }
        [IO.File]::WriteAllText((Join-Path $PWD 'version.json'), ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        git add 'version.json'
        git commit -m ("release: pin {0} (loader {1})" -f $codeSha.Substring(0, 7), $loaderVersion) | Out-Null
        $codeSha = (git rev-parse HEAD).Trim()
        Write-Host "Pinned payload $mainSha / loader $loaderVersion" -ForegroundColor DarkGray
    }
}

git branch -M $Branch
git push -u origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }

gh repo edit $full --default-branch $Branch *> $null

Write-Host "Live at:     https://github.com/$full" -ForegroundColor Green
Write-Host "Raw payload: https://raw.githubusercontent.com/$full/$Branch/main.js" -ForegroundColor Green

