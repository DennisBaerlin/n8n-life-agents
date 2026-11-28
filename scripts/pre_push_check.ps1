#Requires -Version 5.1
# Duenner Wrapper: das Pre-Push-Gate selbst steht in .pre-commit-config.yaml (prek; welche Pruefung in welcher Stufe laeuft,
# steht nur dort: `stages:` je Hook). Der echte .git/hooks/pre-push
# ist prek-eigen (Installer: scripts/install_git_hooks.ps1). Dieses Skript ist der manuelle Befehl
# "Gate jetzt voll ueber alle Dateien laufen lassen".
# Usage:  .\scripts\pre_push_check.ps1
# Voraussetzung: prek (winget install --id j178.Prek). Exit 0 = beide Stages gruen, 1 = mindestens eine rot.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

$prek = (Get-Command prek -ErrorAction SilentlyContinue).Source
if (-not $prek) {
    $cand = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\prek.exe'
    if (Test-Path $cand) { $prek = $cand }
}
if (-not $prek) {
    $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -Filter prek.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { $prek = $pkg.FullName }
}
if (-not $prek) {
    throw "prek nicht gefunden. Installieren:  winget install --id j178.Prek  (dann Shell neu starten)."
}

# Haken mit `-full`-Zwilling laufen in der Push-Stufe voll; mit --all-files liefe dieselbe Pruefung schon in der Commit-Stufe. SKIP gilt
# nur fuer den ersten Lauf: `shellcheck-full` ruft prek selbst auf und erbte die Liste. Test: scripts/dev/pre_push_check_test.ps1.
$ids = @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $RepoRoot '.pre-commit-config.yaml')), '(?m)^\s*- id:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
$twins = @($ids | Where-Object { $ids -ccontains "$_-full" } | Sort-Object -Unique)

Push-Location $RepoRoot
$savedSkip = $env:SKIP
try {
    $env:SKIP = (@($savedSkip -split ',') + $twins | Where-Object { $_ }) -join ','
    & $prek run --all-files --hook-stage pre-commit
    $a = $LASTEXITCODE
    $env:SKIP = $savedSkip
    & $prek run --all-files --hook-stage pre-push
    $b = $LASTEXITCODE
} finally {
    $env:SKIP = $savedSkip
    Pop-Location
}

if ($a -ne 0 -or $b -ne 0) {
    Write-Host ""
    Write-Host "Pre-Push-Gate ROT (commit-stage=$a, pre-push-stage=$b) -- erst fixen." -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "Pre-Push-Gate OK -> Push erlaubt." -ForegroundColor Green
exit 0
