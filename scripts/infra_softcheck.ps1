#Requires -Version 5.1
# WEICHER Pre-Push-Check (aus pre_push_check.ps1 extrahiert) -- blockt NIE (Exit immer 0).
# Bewahrt die alte Gate-Semantik unter prek:
#   - infra_test laeuft gegen das ephemere Docker-Test-Substrat -> nur wenn es laeuft + erreichbar ist,
#     Fehler = WARNUNG (kein Block; kein laufendes Substrat darf einen Push verhindern).
#   - contract_test prueft externe API-Schemata -> netz-abhaengig, Fehler = WARNUNG.
# Das HARTE Gate (db_test) ist ein eigener, blockender prek-Hook (id db-test).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# infra_test nur wenn das Docker-Test-Substrat laeuft + erreichbar ist (gratis, aber substrat-abhaengig
# -> nur Warnung). Verbindung aus .local/n8ntest_state.<container>.json (raus aus Prod; -AllowMissing = $null statt Throw).
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

# Externe API-Contracts (netz-abhaengig -> nur Warnung, blockt nicht).
Write-Host "Contract-Smoke (externe APIs; nur Warnung) ..." -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\contract_test.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNUNG: Contract-Smoke rot -- externe API ggf. down ODER Schema-Drift (Push NICHT blockiert)." -ForegroundColor Yellow
} else {
    Write-Host "  Contract-Smoke gruen." -ForegroundColor Green
}

exit 0
