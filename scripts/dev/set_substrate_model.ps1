#Requires -Version 5.1
# set_substrate_model.ps1 — ein Modell der Zentral-Config (core.config, category='model') im laufenden Test-Substrat
# umschalten, z. B. fuer einen Modell-Vergleich (Sonnet vs. Haiku) mit denselben Agent-Suiten. Wirkt sofort: die
# Agenten lesen ihr Modell bei JEDEM Lauf (Load Config / New-ModelSelectorBundle), kein Redeploy noetig.
#
# Gleicher Schreibweg wie `lifeagents config set model <key> <wert>` (provisioning/lib/config_cli.sh): UPDATE-only,
# nur managed_by='owner'; die DB prueft den Wert (Modell-Trigger + Fremdschluessel auf agent.ai_models) und lehnt
# unbekannte Modelle ab. Nur das ephemere Substrat (Get-TestN8nConnection), nie Prod.
#
# Usage:
#   .\scripts\dev\set_substrate_model.ps1 -Key finance -Model claude-haiku-latest
#   .\scripts\dev\set_substrate_model.ps1 -Key finance -Default      # zurueck auf den Manifest-Standard
#   .\scripts\dev\set_substrate_model.ps1                             # nur anzeigen
param(
    [string]$Key,
    [string]$Model,
    [switch]$Default
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container

function Show-Models {
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-P', 'pager=off', '-c',
        "SELECT key, value, default_value FROM core.config WHERE category = 'model' ORDER BY key;")
    if ($r.Code -ne 0) { throw "core.config lesen fehlgeschlagen: $($r.Output -join "`n")" }
    $r.Output | ForEach-Object { Write-Output $_ }
}

if (-not $Key) { Show-Models; return }
if ($Key -notmatch '^[a-z][a-z0-9_]*$') { throw "-Key '$Key' muss ^[a-z][a-z0-9_]*`$ sein." }
if ($Default -eq [bool]$Model) { throw "Genau eines von -Model <model_key> oder -Default angeben." }
if ($Model -and $Model -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw "-Model '$Model' ist kein gueltiger model_key." }

$valueExpr = if ($Default) { 'default_value' } else { "'$Model'" }
$sql = "UPDATE core.config SET value = $valueExpr WHERE category = 'model' AND key = '$Key' AND managed_by = 'owner' RETURNING key, value;"
$r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-t', '-A', '-F', ' = ', '-c', $sql)
if ($r.Code -ne 0) { throw "Wert fuer model.$Key abgelehnt (Grund siehe DB-Meldung): $($r.Output -join "`n")" }
$row = (($r.Output | Where-Object { $_ -match ' = ' }) -join '').Trim()
if (-not $row) { throw "Unbekannter Config-Key model.$Key im Substrat (nichts geaendert)." }
Write-Host "Substrat $Container : model.$row" -ForegroundColor Green
