#Requires -Version 5.1
# DUENNER WRAPPER (seit prek-Migration). Das Pre-Push-Gate selbst lebt jetzt in
# .pre-commit-config.yaml (prek). Der echte .git/hooks/pre-push ist prek-eigen (Installer:
# scripts/install_git_hooks.ps1 -> prek install). Dieses Skript bleibt als manueller
# "Gate jetzt voll laufen lassen"-Befehl + fuer Doku-/Tool-Aufrufer, die den alten Namen kennen.
#
# Frueher: bespoke Aggregator (db_test/config_test/workflow_lint/doc_lint/contract_lint/Catalog/
# fn-Katalog hart + Dirty-Surface-Warner). Alle diese Checks laufen jetzt als prek-Hooks
# (commit-stage: die deterministischen Linter; pre-push-stage: db_test/infra_test + llm_suite_advice).

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
    # Voller Gate-Lauf: erst die commit-stage-Hooks, dann die pre-push-Hooks -- alle ueber alle Dateien.
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
