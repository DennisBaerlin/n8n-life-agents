#Requires -Version 5.1
# Selbsttest der Markerzeile NEXT_STEP im Direkt-Test (scripts/lib/next_step_marker.ps1). Kein Substrat, keine Kosten.
# Haelt fest: Der Direkt-Test nimmt die Zeile wie der Relay aus dem Agententext und gibt sie als Knopf mit; das Muster ist
# dasselbe, das der Relay-Baustein in sein JavaScript einsetzt (eine Quelle, kein zweites Regex). Dazu die Beschriftung des
# System-Schritts (Get-SystemNextStepLabel), NEXT_STEP_BUTTON im Judge-Prompt (lib/judge_prompt.ps1) und dessen Verdrahtung in n8n_test.ps1.
# Usage:  .\scripts\dev\next_step_marker_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$CRED_TELEGRAM = @{ id = 'x'; name = 'x' }
. (Join-Path $repo 'scripts\build\lib\build_helpers.ps1')
. (Join-Path $repo 'scripts\lib\judge_prompt.ps1')
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}

Write-Host "Trennen der Markerzeile"
$s = Split-NextStepMarker "Gern! Als Naechstes die Haushalts-Einrichtung.`nNEXT_STEP"
Assert-That ($s.marker -eq $true -and $s.text -eq 'Gern! Als Naechstes die Haushalts-Einrichtung.') 'letzte Zeile NEXT_STEP: aus dem Text, marker = true'
$s = Split-NextStepMarker "Gern!`n  NEXT_STEP  `nOder schreib mir."
Assert-That ($s.marker -eq $true -and $s.text -eq "Gern!`nOder schreib mir.") 'auch mitten im Text und mit Leerzeichen: Zeile weg (wie der Relay)'
$s = Split-NextStepMarker "Gern!`r`nNEXT_STEP`r`n"
Assert-That ($s.marker -eq $true -and $s.text -eq 'Gern!') 'CRLF'
$s = Split-NextStepMarker 'Das Wort NEXT_STEP im Satz oder NEXT_STEP: Wert bleibt stehen.'
Assert-That ($s.marker -eq $false -and $s.text -match 'NEXT_STEP im Satz') 'nur eine ganze Zeile ist der Marker'
$s = Split-NextStepMarker ''
Assert-That ($s.marker -eq $false -and $s.text -eq '') 'leerer Text'

Write-Host "Ein Muster fuer Relay und Direkt-Test"
$chain = New-TelegramRelayChain -Name 'T' -Pos @(0, 0) -TextJs "'x'" -ChatIdExpr '1'
$js = [string]$chain.Nodes[0].parameters.jsCode
$m = [regex]::Match($js, '!/(.+?)/\.test\(l\)')
Assert-That ($m.Success -and $m.Groups[1].Value -ceq $script:NextStepMarkerPattern) "Relay-Code filtert mit demselben Muster ($($script:NextStepMarkerPattern))"

Write-Host "Knopf und Judge-Prompt"
$rd = '{ "Household status read": [ { "data": { "main": [ [ { "json": { "step": { "kind": "section", "label": "Kredite" } } } ] ] } } ], "Guide Agent": [ { "data": { "main": [ [ { "json": { "output": "x" } } ] ] } } ] }' | ConvertFrom-Json
Assert-That ((Get-SystemNextStepLabel $rd) -eq 'Kredite') 'Beschriftung des System-Schritts aus dem runData'
Assert-That ((Get-SystemNextStepLabel ('{ "Guide Agent": [ { "data": { "main": [ [ { "json": { "output": "x" } } ] ] } } ] }' | ConvertFrom-Json)) -eq '') 'ohne Schritt-Knoten leer'
$with = [pscustomobject]@{ task = 'x'; actual_output = 'Antwort'; next_step_button = 'Kredite' }
Assert-That ((Format-JudgeUserText $with) -match 'NEXT_STEP_BUTTON[^\n]*\nKredite\n') 'User-Text traegt den Knopf'
Assert-That ((Format-JudgeUserText ([pscustomobject]@{ task = 'x'; actual_output = 'Antwort' })) -notmatch 'NEXT_STEP_BUTTON') 'ohne Knopf kein Abschnitt'
Assert-That ((Get-JudgeSystemText) -match 'NEXT_STEP_BUTTON' -and (Get-JudgeSystemText 'approved') -match 'NEXT_STEP_BUTTON') 'System-Text erklaert das Feld in beiden Fassungen'
$nt = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\n8n_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($nt -match 'Split-NextStepMarker' -and $nt -match 'next_step_button = \$stepLabel') 'n8n_test trennt die Zeile und schreibt next_step_button ins Buendel'

if ($failed -eq 0) { Write-Host "next_step_marker_test: alles gruen." -ForegroundColor Green } else { Write-Host "next_step_marker_test: $failed Fehler." -ForegroundColor Red }
exit $failed
