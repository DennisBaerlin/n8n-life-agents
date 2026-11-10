#Requires -Version 5.1
# Selbsttest von Get-ToolCall / Get-CalledTool in scripts/dev/test_n8n_state.ps1. Kein Substrat, keine Kosten.
# Nachgebautes runData eines Agent-Laufs mit zwei Werkzeug-Aufrufen nacheinander: der n8n-Aktions-Log des Agent-Knotens
# (metadata.subNodeExecutionData.actions) nennt nur den letzten Aufruf; die Werkzeug-Knoten selbst tragen startTime und
# Eingabe (inputOverride.ai_tool), ein Lauf hinter einer HITL-Karte nur die Ausgabe (data.ai_tool). Erwartet: alle Aufrufe in
# zeitlicher Reihenfolge, Get-CalledTool = der erste.
# Usage:  .\scripts\dev\tool_call_order_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\dev\test_n8n_state.ps1')

$json = @'
{
  "Demo Agent": [ { "startTime": 100, "metadata": { "subNodeExecutionData": { "actions": [
      { "action": { "nodeName": "tool_create_account", "input": { "name": "Testbank Giro" } }, "nodeName": "tool_create_account" } ] } } } ],
  "Postgres Chat Memory": [ { "startTime": 101, "inputOverride": { "ai_memory": [ [ { "json": { "action": "loadMemoryVariables" } } ] ] } } ],
  "tool_create_account": [ { "startTime": 300, "inputOverride": {}, "data": { "ai_tool": [ [ { "json": { "ok": false, "cancelled": true } } ] ] } } ],
  "load_context": [ { "startTime": 150, "inputOverride": { "ai_tool": [ [ { "json": { "name": "family" } } ] ] } } ],
  "tool_import_bank_export": [ { "startTime": 200, "inputOverride": { "ai_tool": [ [ { "json": { "file_id": "mock_file_b" } } ] ] } } ]
}
'@
$rd = $json | ConvertFrom-Json
$fail = 0
$calls = @(Get-ToolCall $rd 'Demo Agent')
$names = ($calls | ForEach-Object { $_.tool }) -join ','
if ($names -ne 'load_context,tool_import_bank_export,tool_create_account') { Write-Host "[FAIL] Reihenfolge: $names" -ForegroundColor Red; $fail++ }
else { Write-Host "[PASS] Reihenfolge aus den Werkzeug-Knoten: $names" -ForegroundColor Green }
$first = Get-CalledTool $rd 'Demo Agent'
if ($first -ne 'tool_import_bank_export') { Write-Host "[FAIL] Get-CalledTool: $first" -ForegroundColor Red; $fail++ }
else { Write-Host '[PASS] Get-CalledTool = erster Write-Aufruf' -ForegroundColor Green }
$imp = $calls | Where-Object { $_.tool -eq 'tool_import_bank_export' } | Select-Object -First 1
if ($null -eq $imp -or $imp.inputObj.file_id -ne 'mock_file_b') { Write-Host '[FAIL] Eingabe des Werkzeug-Knotens fehlt' -ForegroundColor Red; $fail++ }
else { Write-Host '[PASS] Eingabe aus inputOverride' -ForegroundColor Green }
# Lauf, der auf eine HITL-Karte gewartet hat: leeres inputOverride, Eingabe aus dem Aktions-Log
$card = $calls | Where-Object { $_.tool -eq 'tool_create_account' } | Select-Object -First 1
if ($null -eq $card -or $card.inputObj.name -ne 'Testbank Giro') { Write-Host '[FAIL] Karten-Lauf ohne Eingabe' -ForegroundColor Red; $fail++ }
else { Write-Host '[PASS] Karten-Lauf: Eingabe aus dem Aktions-Log' -ForegroundColor Green }

# Ohne Werkzeug-Knoten im runData (aelteres Format): Aktions-Log bleibt die Quelle
$rd2 = (@'
{ "Demo Agent": [ { "metadata": { "subNodeExecutionData": { "actions": [
    { "action": { "nodeName": "tool_book_transaction", "input": { "amount": 5 } } } ] } } } ] }
'@) | ConvertFrom-Json
if ((Get-CalledTool $rd2 'Demo Agent') -ne 'tool_book_transaction') { Write-Host '[FAIL] Rueckfall auf den Aktions-Log' -ForegroundColor Red; $fail++ }
else { Write-Host '[PASS] Rueckfall auf den Aktions-Log' -ForegroundColor Green }
exit $fail
