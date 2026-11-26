#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/derived_input_lint.ps1 in einem Wegwerf-Baum (-Root): ein Schreib-Werkzeug mit einem
# abgeleiteten Feld (Hoechststand) oder einer Rechen-Anweisung in der Feld-Beschreibung muss rot werden; Verneinung
# ("never convert"), Lese-Werkzeug, begruendete Ausnahme gruen; eine Ausnahme ohne Treffer oder ohne Grund rot.
# Kein Docker, kein git-Schreibzugriff.
# Usage: .\scripts\dev\derived_input_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\derived_input_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function New-Wf([string]$Tool, [string]$Field, [string]$Desc, [string]$Field2, [string]$Desc2) {
    $value = [ordered]@{ $Field = "={{ `$fromAI('$Field', '$Desc', 'string') }}" }
    if ($Field2) { $value[$Field2] = "={{ `$fromAI('$Field2', '$Desc2', 'string') }}" }
    $node = [ordered]@{ type = '@n8n/n8n-nodes-langchain.toolWorkflow'; name = $Tool
        parameters = [ordered]@{ name = $Tool; workflowInputs = [ordered]@{ value = $value } } }
    return ([ordered]@{ name = 'agent.x'; nodes = @($node) } | ConvertTo-Json -Depth 10)
}

function Test-Case([string]$Name, [string]$Wf, [string]$Allow, [bool]$ExpectRed, [string]$ExpectText) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('dil_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'packages\x\workflows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts\build') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $root 'packages\x\workflows\a-agent.x.json'), $Wf, $u8)
    if ($Allow) { [System.IO.File]::WriteAllText((Join-Path $root 'scripts\build\derived_input_allowlist.json'), $Allow, $u8) }
    try {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}

Test-Case 'Hoechststand als Eingang ist rot' (New-Wf 'tool_create_x' 'reference_value' 'peak of the series') '' $true 'reference_value (N)'
Test-Case 'Rechen-Anweisung ist rot' (New-Wf 'tool_book_x' 'amount' 'amount converted to EUR at the rate of today') '' $true 'amount (D)'
Test-Case 'Verneinung ist gruen' (New-Wf 'tool_book_x' 'amount' 'amount as on the receipt, never converted to EUR') '' $false ''
Test-Case 'Lese-Werkzeug ist gruen' (New-Wf 'tool_list_x' 'reference_value' 'filter') '' $false ''
Test-Case 'Begruendete Ausnahme ist gruen' (New-Wf 'tool_create_x' 'reference_value' 'contract value') `
    '[{"tool":"tool_create_x","field":"reference_value","rule":"N","reason":"Wert laut Vertrag"}]' $false ''
Test-Case 'Ausnahme ohne Treffer ist rot' (New-Wf 'tool_create_x' 'label' 'name') `
    '[{"tool":"tool_create_x","field":"reference_value","rule":"N","reason":"Wert laut Vertrag"}]' $true 'ohne Treffer'
Test-Case 'Verneinung in anderem Satzteil ist rot' (New-Wf 'tool_create_x' 'monthly' 'calculate it from the yearly amount; never negative') '' $true 'monthly (D)'
Test-Case 'Zwei begruendete Ausnahmen sind gruen' (New-Wf 'tool_create_x' 'reference_value' 'contract value' 'peak' 'contract peak') `
    '[{"tool":"tool_create_x","field":"reference_value","rule":"N","reason":"Wert laut Vertrag"},{"tool":"tool_create_x","field":"peak","rule":"N","reason":"Wert laut Vertrag"}]' $false ''
Test-Case 'Ausnahme ohne Grund ist rot' (New-Wf 'tool_create_x' 'reference_value' 'contract value') `
    '[{"tool":"tool_create_x","field":"reference_value","rule":"N","reason":""}]' $true 'unvollst'

if ($fails -eq 0) { Write-Host 'derived_input_lint_test: alle Faelle bestanden' }
exit $fails
