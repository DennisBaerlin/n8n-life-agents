#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/size_lint.ps1 in einem Wegwerf-Baum (-Root): Datei ueber einer Grenze ohne Decke, gewachsene Datei,
# Decke ohne Anlass oder zu weit ueber dem Wert, Agent ohne Eintrag, Agent mit einem Werkzeug mehr, zu lange Sticky-Note muessen rot
# werden; die passenden Gegenstuecke gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\size_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\size_lint.ps1'
$fails = 0

. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')
function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText) { Test-LintCase -Lint $lint -Name $Name -Files $Files -ExpectRed $ExpectRed -ExpectText $ExpectText }

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$B = 'scripts/build/size_budget.json'
$P = 'packages'
$Def = "$P/x/build/a.ps1"
$Rule = '{ "id": "defs", "include": "^packages/[^/]+/build/.*\\.ps1$", "exclude": "/gen_", "lines": 3, "bytes": 100, "line_chars": 20 }'
function New-Budget([string]$Files = '', [string]$Agents = '', [string]$Rules = $Rule, [string]$Stickies = '') {
    return '{ "headroom_pct": 10, "sticky_chars": 10, "rules": [' + $Rules + '], "files": [' + $Files + '], "agents": [' + $Agents + '], "stickies": [' + $Stickies + '] }'
}
# Ein Workflow ohne Agent mit einer Sticky-Note 'Doc' des angegebenen Textes.
function New-StickyWorkflow([string]$Text) {
    return '{ "name": "core.x", "nodes": [{ "name": "Doc", "type": "n8n-nodes-base.stickyNote", "parameters": { "content": "' + $Text + '" } }], "connections": {} }'
}
# Ein Workflow mit einem Agent-Knoten 'A' und je Eintrag in $Tools einem Werkzeug-Knoten (Name = Beschreibung) an dessen ai_tool-Eingang.
function New-Workflow([string[]]$Tools, [string]$AgentType = '@n8n/n8n-nodes-langchain.agent') {
    $nodes = @('{ "name": "A", "type": "' + $AgentType + '", "parameters": {} }')
    $conns = @()
    foreach ($t in $Tools) {
        $nodes += '{ "name": "' + $t + '", "type": "@n8n/n8n-nodes-langchain.toolWorkflow", "parameters": { "description": "' + $t + '" } }'
        $conns += '"' + $t + '": { "ai_tool": [[{ "node": "A", "type": "ai_tool", "index": 0 }]] }'
    }
    return '{ "name": "agent.x", "nodes": [' + ($nodes -join ', ') + '], "connections": { ' + ($conns -join ', ') + ' } }'
}
$Wf = "$P/x/workflows/id1-agent.x.json"
$Three = "a`nb`nc`n"
$Five  = "a`nb`nc`nd`ne`n"

Write-Host 'size_lint_test'
Test-Case 'Regeldatei fehlt ist rot' @{ $Def = $Three } $true 'size_budget.json fehlt'
Test-Case 'Datei an der Grenze ist gruen' @{ $B = (New-Budget); $Def = $Three } $false ''
Test-Case 'Datei ueber der Grenze ohne Decke ist rot' @{ $B = (New-Budget); $Def = $Five } $true 'lines = 5 ueber der Grenze 3'
Test-Case 'Datei ueber der Grenze mit Decke ist gruen' @{ $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 5 }')); $Def = $Five } $false ''
Test-Case 'gewachsene Datei ist rot' @{ $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 4 }')); $Def = $Five } $true 'ueber der Decke 4'
Test-Case 'Decke fuer eine Datei unter der Grenze ist rot' @{ $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 5 }')); $Def = $Three } $true 'unter der Grenze'
Test-Case 'Decke weit ueber dem Wert ist rot' @{ $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 9 }')); $Def = $Five } $true 'senken'
Test-Case 'Decke fuer eine fehlende Datei ist rot' @{ $B = (New-Budget ('{ "path": "' + "$P/x/build/weg.ps1" + '", "lines": 5 }')); $Def = $Three } $true 'gibt es nicht'
Test-Case 'doppelter Eintrag ist rot' @{ $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 5 }, { "path": "' + $Def + '", "lines": 5 }')); $Def = $Five } $true 'doppelt'
Test-Case 'Eintrag ohne Decke ist rot' @{ $B = (New-Budget ('{ "path": "' + $Def + '" }')); $Def = $Three } $true 'nennt keine Decke'
Test-Case 'Regel ohne Grenze ist rot' @{ $B = (New-Budget '' '' '{ "id": "leer", "include": "^x" }'); $Def = $Three } $true 'braucht id'
Test-Case 'zu lange Zeile ist rot' @{ $B = (New-Budget); $Def = ('x' * 21) + "`n" } $true 'line_chars = 21'
Test-Case 'zu viele Bytes sind rot (Umlaut zaehlt zwei)' @{ $B = (New-Budget); $Def = ((([string][char]0xE4) * 17 + "`n") * 3) } $true 'bytes = 105'
Test-Case 'CRLF zaehlt wie LF' @{ $B = (New-Budget); $Def = "a`r`nb`r`nc`r`n" } $false ''
Test-Case 'Datei ausserhalb der Regeln zaehlt nicht' @{ $B = (New-Budget); "$P/x/other/a.ps1" = $Five } $false ''
Test-Case 'exclude nimmt die Datei aus' @{ $B = (New-Budget); "$P/x/build/gen_a.ps1" = $Five } $false ''

$entry = '{ "agent": "agent.x / A", "tools": 2, "description_chars": 6, "longest_description": 4 }'
Test-Case 'Agent ohne Eintrag ist rot' @{ $B = (New-Budget); $Wf = (New-Workflow 't1', 'tool') } $true 'hat keinen Eintrag'
Test-Case 'Agent mit passendem Eintrag ist gruen' @{ $B = (New-Budget '' $entry); $Wf = (New-Workflow 't1', 'tool') } $false ''
Test-Case 'ein Werkzeug mehr ist rot' @{ $B = (New-Budget '' $entry); $Wf = (New-Workflow 't1', 'tool', 't') } $true 'tools = 3 ueber der Decke 2'
Test-Case 'ein Werkzeug weniger verlangt die niedrigere Decke' @{ $B = (New-Budget '' '{ "agent": "agent.x / A", "tools": 2, "description_chars": 4, "longest_description": 4 }'); $Wf = (New-Workflow 'tool') } $true 'auf hoechstens 1 senken'
Test-Case 'laengere Beschreibung ist rot' @{ $B = (New-Budget '' $entry); $Wf = (New-Workflow 't1', 'tool-lang') } $true 'longest_description = 9 ueber der Decke 4'
Test-Case 'Eintrag fuer einen Agenten, den es nicht gibt, ist rot' @{ $B = (New-Budget '' $entry); $Def = $Three } $true 'gibt es in den gebauten Workflows nicht'
Test-Case 'ein Knoten anderen Typs ist kein Agent' @{ $B = (New-Budget); $Wf = (New-Workflow @('t1') '@n8n/n8n-nodes-langchain.agentTool') } $false ''

$note = '{ "sticky": "core.x / Doc", "chars": 12 }'
Test-Case 'kurze Sticky-Note ist gruen' @{ $B = (New-Budget); $Wf = (New-StickyWorkflow 'kurz') } $false ''
Test-Case 'lange Sticky-Note ohne Decke ist rot' @{ $B = (New-Budget); $Wf = (New-StickyWorkflow 'zwoelfzeichen') } $true '13 Zeichen ueber der Grenze 10'
Test-Case 'lange Sticky-Note mit Decke ist gruen' @{ $B = (New-Budget -Stickies $note); $Wf = (New-StickyWorkflow 'elf zeichen!') } $false ''
Test-Case 'gewachsene Sticky-Note ist rot' @{ $B = (New-Budget -Stickies $note); $Wf = (New-StickyWorkflow 'dreizehn text') } $true 'ueber der Decke 12'
Test-Case 'Decke fuer eine kurze Sticky-Note ist rot' @{ $B = (New-Budget -Stickies $note); $Wf = (New-StickyWorkflow 'kurz') } $true 'unter der Grenze 10'
Test-Case 'Decke fuer eine Sticky-Note, die es nicht gibt, ist rot' @{ $B = (New-Budget -Stickies $note); $Def = $Three } $true 'gibt es in den gebauten Workflows nicht'

# -Update: eine zu niedrige Decke bekommt den Wert, eine gueltige bleibt, ein Eintrag ohne Datei entfaellt, der Agent kommt dazu;
# danach ist der Lint gruen.
$twenty = (('x' + "`n") * 20)
$root = New-TestTree @{
    $B = (New-Budget ('{ "path": "' + $Def + '", "lines": 4 }, { "path": "' + "$P/x/build/b.ps1" + '", "lines": 21 }, { "path": "' + "$P/x/build/weg.ps1" + '", "lines": 9 }'))
    $Def = $Five; "$P/x/build/b.ps1" = $twenty; $Wf = (New-Workflow 't1', 'tool')
} 'lt'
try {
    $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $null = & $shell -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root -Update
    $null = & $shell -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root
    $green = ($LASTEXITCODE -eq 0)
    $txt = [System.IO.File]::ReadAllText((Join-Path $root $B))
    if ($green -and $txt -match 'a\.ps1", "lines": 5 ' -and $txt -match 'b\.ps1", "lines": 21 ' -and $txt -notmatch 'weg\.ps1' -and $txt -match '"tools": 2, "description_chars": 6') {
        Write-Host '  PASS -Update zieht die Decken nach und laesst gueltige stehen' -ForegroundColor Green
    } else { Write-Host "  FAIL -Update (gruen danach: $green): $txt" -ForegroundColor Red; $fails++ }
} finally { Remove-Item -Recurse -Force $root }

if ($fails -eq 0) { Write-Host 'size_lint_test: alle Faelle bestanden.' -ForegroundColor Green } else { Write-Host "size_lint_test: $fails Fehler." -ForegroundColor Red }
exit $fails
