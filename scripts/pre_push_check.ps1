#Requires -Version 5.1
# Duenner Wrapper: das Pre-Push-Gate selbst steht in .pre-commit-config.yaml (prek; commit-stage: die
# deterministischen Linter, pre-push-stage: db_test/infra_test + llm_suite_advice). Der echte .git/hooks/pre-push
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

Push-Location $RepoRoot
try {
    & $prek run --all-files --hook-stage pre-commit
    $a = $LASTEXITCODE
    & $prek run --all-files --hook-stage pre-push
    $b = $LASTEXITCODE
} finally {
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
