#Requires -Version 5.1
# Weicher Pre-Push-Check, blockt nie (Exit immer 0):
#   - infra_test laeuft gegen das ephemere Docker-Test-Substrat -> nur wenn es laeuft + erreichbar ist,
#     Fehler = Warnung (kein laufendes Substrat darf einen Push verhindern).
#   - contract_test prueft externe API-Schemata -> netz-abhaengig, Fehler = Warnung.
# Das harte Gate (db_test) ist ein eigener, blockender prek-Hook (id db-test).
# Aufruf: .\scripts\infra_softcheck.ps1 (ohne Parameter; ruft infra_test.ps1 und contract_test.ps1 auf).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Verbindung aus .local/n8ntest_state.<container>.json; -AllowMissing liefert $null statt Throw.
Write-Host "Infra-Tests (wenn das Test-Substrat laeuft; nur Warnung) ..." -ForegroundColor Cyan
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn = Get-TestN8nConnection -AllowMissing
$reachable = $false
if ($conn) {
    try { Invoke-WebRequest -Uri $conn.Url -Method Head -TimeoutSec 3 -UseBasicParsing | Out-Null; $reachable = $true }
    catch { if ($_.Exception.Response) { $reachable = $true } }  # HTTP-Antwort (auch 404) = erreichbar
}
if ($reachable) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\infra_test.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNUNG: infra_test rot -- bitte vor dem naechsten Deploy ansehen (Push NICHT blockiert)." -ForegroundColor Yellow
    } else {
        Write-Host "  Infra-Tests gruen." -ForegroundColor Green
    }
} else {
    Write-Host "  n8n nicht erreichbar -> infra_test uebersprungen (kein Block)." -ForegroundColor DarkGray
}

Write-Host "Contract-Smoke (externe APIs; nur Warnung) ..." -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\contract_test.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNUNG: Contract-Smoke rot -- externe API ggf. down ODER Schema-Drift (Push NICHT blockiert)." -ForegroundColor Yellow
} else {
    Write-Host "  Contract-Smoke gruen." -ForegroundColor Green
}

exit 0
