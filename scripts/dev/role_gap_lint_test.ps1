#Requires -Version 5.1
# Fall-Tests der Rollen-Luecken-Pruefung (scripts/lib/role_call_pairs.ps1, Zweig D von role_test_lint.ps1) in einem
# Wegwerf-Baum: Aufruf-Paare aus Workflows, Rollen-Segmente der Tests, Abgleich mit der schrumpfenden Liste, Katalog-Block.
# Kein Docker, kein git. Usage: .\scripts\dev\role_gap_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\role_call_pairs.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:fails++ }
}
function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rgl_' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
    }
    return $root
}
function Wf([string]$Cred, [string]$Query) {
    return (@{ name = 'agent.x'; nodes = @(@{ name = 'n'; credentials = @{ postgres = @{ id = $Cred } }; parameters = @{ query = $Query } }) } | ConvertTo-Json -Depth 8)
}

$P = 'packages'; $TD = 'tests/db'
$tree = New-Tree @{
    "$P/finance/workflows/a.json" = (Wf '__CRED_POSTGRES_FINANCE_RW__' "SELECT finance.fn_book_x(`$1::jsonb), core.fn_today() -- core.fn_kommentar(")
    "$P/finance/workflows/b.json" = (Wf '__CRED_POSTGRES_WRITE__' 'SELECT finance.fn_owner_only()')
    "$P/core/workflows/c.json" = (Wf '__CRED_POSTGRES_CORE_RO__' 'SELECT agent.fn_owner_person_id()')
    "$TD/cross/test_a.sql" = "BEGIN;`nDO `$`$ BEGIN`n  SET LOCAL ROLE finance_rw;`n  PERFORM finance.fn_book_x('{}'::jsonb);`n  RESET ROLE;`n  PERFORM agent.fn_owner_person_id();`nEND `$`$;`nROLLBACK;`n"
}
try {
    $pairs = @(Get-RoleCallPairs -Root $tree)
    $keys = @($pairs | ForEach-Object { "$($_.Role)|$($_.Fn)" } | Sort-Object)
    Check 'Paare: Rolle und fn aus dem Postgres-Knoten, Owner-Rolle ausgenommen' (($keys -join ',') -eq 'core_ro|agent.fn_owner_person_id,finance_rw|core.fn_today,finance_rw|finance.fn_book_x') ($keys -join ',')

    $tested = @(Get-RoleTestedFns -Root $tree)
    Check 'getestet = Name im Rollen-Segment, Aufruf nach RESET ROLE zaehlt nicht' (($tested -join ',') -eq 'finance.fn_book_x') ($tested -join ',')

    $r = Compare-RoleGap -Pairs $pairs -Tested $tested -Allow @{}
    Check 'ohne Liste: ungetestete fns sind Fehler' ((@($r.Errors) -join '|') -match 'core\.fn_today' -and (@($r.Errors) -join '|') -match 'agent\.fn_owner_person_id' -and (@($r.Errors) -join '|') -notmatch 'fn_book_x') (@($r.Errors) -join '|')

    $r = Compare-RoleGap -Pairs $pairs -Tested $tested -Allow @{ 'core.fn_today' = 'Grund'; 'agent.fn_owner_person_id' = 'Grund' }
    Check 'mit Liste: gruen' (@($r.Errors).Count -eq 0) (@($r.Errors) -join '|')

    $r = Compare-RoleGap -Pairs $pairs -Tested $tested -Allow @{ 'core.fn_today' = 'Grund'; 'agent.fn_owner_person_id' = 'Grund'; 'finance.fn_book_x' = 'Grund' }
    Check 'Eintrag fuer getestete fn ist Orphan (Liste schrumpft)' ((@($r.Errors) -join '|') -match 'finance\.fn_book_x') (@($r.Errors) -join '|')

    $r = Compare-RoleGap -Pairs $pairs -Tested $tested -Allow @{ 'core.fn_today' = 'Grund'; 'agent.fn_owner_person_id' = 'Grund'; 'finance.fn_weg' = 'Grund' }
    Check 'Eintrag fuer nicht mehr aufgerufene fn ist Orphan' ((@($r.Errors) -join '|') -match 'finance\.fn_weg') (@($r.Errors) -join '|')

    $r = Compare-RoleGap -Pairs $pairs -Tested $tested -Allow @{ 'core.fn_today' = ' '; 'agent.fn_owner_person_id' = 'Grund' }
    Check 'Eintrag ohne Grund ist Fehler' ((@($r.Errors) -join '|') -match 'Grund') (@($r.Errors) -join '|')

    $blk = Get-RoleCatalogBlock -Pairs $pairs
    Check 'Katalog-Block: sortiert, je Paar eine Zeile' (($blk -match "\('core_ro', 'agent.fn_owner_person_id'\)") -and ($blk -match "\('finance_rw', 'finance.fn_book_x'\)") -and ($blk.IndexOf('core_ro') -lt $blk.IndexOf('finance_rw')))
} finally { Remove-Item -Recurse -Force $tree -ErrorAction SilentlyContinue }

if ($fails -eq 0) { Write-Host 'PASS role_gap_lint_test' -ForegroundColor Green } else { Write-Host "role_gap_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
