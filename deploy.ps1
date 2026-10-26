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

# Pin version.json to the exact commit so raw.githubusercontent.com CDN caching
# can never serve an older payload than the version it advertises.
$codeSha = (git rev-parse HEAD).Trim()
if (Test-Path 'version.json') {
    $v = Get-Content 'version.json' -Raw | ConvertFrom-Json
    $pinned = "https://raw.githubusercontent.com/$full/$codeSha/main.js"
    if ($v.url -ne $pinned) {
        $v.url = $pinned
        [IO.File]::WriteAllText((Join-Path $PWD 'version.json'), ($v | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        git add 'version.json'
        git commit -m ("release: pin payload to {0}" -f $codeSha.Substring(0, 7)) | Out-Null
        $codeSha = (git rev-parse HEAD).Trim()
        Write-Host "Pinned payload to $($pinned)" -ForegroundColor DarkGray
    }
}

git branch -M $Branch
git push -u origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }

gh repo edit $full --default-branch $Branch *> $null

Write-Host "Live at:     https://github.com/$full" -ForegroundColor Green
Write-Host "Raw payload: https://raw.githubusercontent.com/$full/$Branch/main.js" -ForegroundColor Green

