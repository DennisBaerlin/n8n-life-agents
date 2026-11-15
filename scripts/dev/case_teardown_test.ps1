#Requires -Version 5.1
# Selbsttest des Fall-Feldes teardown_sql (Register-/Complete-/Invoke-TestCaseTeardown in dev/test_n8n_state.ps1). Kein Substrat, keine Kosten.
# Haelt fest: das Feld wird vor dem setup_sql gemerkt (laeuft also auch nach einer gescheiterten Vorbereitung), genau einmal ausgefuehrt,
# ein Fehler kommt als Meldung zurueck (wirft nie, laeuft im finally) und jeder Treiber mit setup_sql ruft es vor dem naechsten Fall und am Lauf-Ende.
# Usage:  .\scripts\dev\case_teardown_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'test_n8n_state.ps1')
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}

# Attrappe: Invoke-TestN8nPsql merkt sich das SQL und liefert den vorgegebenen Exit-Code.
$script:Sent = @(); $script:NextCode = 0
function Invoke-TestN8nPsql { param([string]$Container, [string[]]$PsqlArgs) $script:Sent += ($PsqlArgs -join ' '); [pscustomobject]@{ Code = $script:NextCode; Output = @('Attrappe-Fehler') } }
function Case([string]$Json) { $Json | ConvertFrom-Json }

Write-Host "Helfer"
Register-TestCaseTeardown (Case '{"id":"a1","teardown_sql":"UPDATE t SET x = 1;"}')
Assert-That ($script:Sent.Count -eq 0) 'Register fuehrt noch nichts aus'
$r = Complete-TestCaseTeardown -Container 'c'
Assert-That ($null -eq $r -and $script:Sent.Count -eq 1 -and $script:Sent[0] -match 'UPDATE t SET x = 1;') 'Complete fuehrt das merkte SQL aus'
$r = Complete-TestCaseTeardown -Container 'c'
Assert-That ($null -eq $r -and $script:Sent.Count -eq 1) 'zweites Complete fuehrt nichts mehr aus (genau einmal)'
Register-TestCaseTeardown (Case '{"id":"a2"}')
[void](Complete-TestCaseTeardown -Container 'c')
Assert-That ($script:Sent.Count -eq 1) 'Fall ohne teardown_sql: nichts wird ausgefuehrt'
Register-TestCaseTeardown (Case '{"id":"a3","teardown_sql":"SELECT 1;"}')
Register-TestCaseTeardown (Case '{"id":"a4"}')
[void](Complete-TestCaseTeardown -Container 'c')
Assert-That ($script:Sent.Count -eq 1) 'Register des naechsten Falls ersetzt das alte Feld (kein Rest eines anderen Falls)'

$script:NextCode = 1
Register-TestCaseTeardown (Case '{"id":"a5","teardown_sql":"SELECT boom;"}')
$msg = Complete-TestCaseTeardown -Container 'c'
Assert-That ($msg -match '\[a5\]' -and $msg -match 'teardown_sql fehlgeschlagen' -and $msg -match 'Attrappe-Fehler') 'SQL-Fehler: Meldung mit Fall-id und Datenbank-Text, ohne zu werfen'
$script:NextCode = 0
Assert-That ($null -eq (Complete-TestCaseTeardown -Container 'c')) 'nach einem Fehler bleibt nichts liegen (kein Endlos-Wiederholen)'

Write-Host "Verdrahtung der Treiber"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$drivers = @{
    'scripts\n8n_test.ps1'              = $true
    'scripts\e2e_test.ps1'              = $true
    'scripts\multiturn_test.ps1'        = $true
    'scripts\dev\mock_route_test.ps1'   = $true
}
foreach ($rel in $drivers.Keys) {
    $t = [System.IO.File]::ReadAllText((Join-Path $repo $rel), $utf8)
    $reg = $t.IndexOf('Register-TestCaseTeardown $tc'); $setup = [regex]::Match($t, '(try \{ |^\s*)Invoke-TestCaseSetup -Container', 'Multiline').Index
    $completeCount = ([regex]::Matches($t, 'Complete-TestCaseTeardown -Container \$Container')).Count
    Assert-That ($reg -ge 0 -and $reg -lt $setup) "$rel merkt teardown_sql vor dem setup_sql"
    $expect = if ($rel -like '*mock_route_test*') { 1 } else { 2 }   # mock_route_test: ein finally je Fall; sonst vor dem naechsten Fall + am Lauf-Ende
    Assert-That ($completeCount -ge $expect) "$rel fuehrt es aus ($completeCount Stellen, mind. $expect)"
}
$mr = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\dev\mock_route_test.ps1'), $utf8)
Assert-That ($mr -match '(?s)finally \{[^}]*fn_clear_e2e_data[^}]*\}?[^}]*Complete-TestCaseTeardown') 'mock_route_test: im finally jedes Falls, nach dem fn_clear_e2e_data'

Write-Host "precondition_sql (Invoke-TestCaseSetup -Precondition)"
$script:Out = @('t')
function Invoke-TestN8nPsql { param([string]$Container, [string[]]$PsqlArgs) $script:Sent += ($PsqlArgs -join ' '); [pscustomobject]@{ Code = $script:NextCode; Output = $script:Out } }
$script:Sent = @()
Invoke-TestCaseSetup -Container 'c' -Sql 'SELECT 1;' -Precondition '1 = 1'
Assert-That ($script:Sent.Count -eq 2 -and $script:Sent[1] -match 'SELECT COALESCE\(\(1 = 1\), false\);') 'wahre Vorbedingung: nach dem setup_sql geprueft, Fall laeuft weiter'
$script:Sent = @(); Invoke-TestCaseSetup -Container 'c' -Sql 'SELECT 1;' -Precondition ''
Assert-That ($script:Sent.Count -eq 1) 'ohne precondition_sql: keine zweite Abfrage'
$script:Out = @('f'); $threw = ''
try { Invoke-TestCaseSetup -Container 'c' -Sql 'SELECT 1;' -Precondition '1 = 2' } catch { $threw = $_.Exception.Message }
Assert-That ($threw -match 'precondition_sql nicht erfuellt' -and $threw -match '1 = 2') 'falsche Vorbedingung: Fall rot mit dem Ausdruck, bevor ein bezahlter Aufruf losgeht'
$script:Out = @(); $threw = ''
try { Invoke-TestCaseSetup -Container 'c' -Sql 'SELECT 1;' -Precondition 'NULL' } catch { $threw = $_.Exception.Message }
Assert-That ($threw -match 'nicht erfuellt') 'leere Antwort (NULL) zaehlt als nicht erfuellt'
foreach ($rel in $drivers.Keys) {
    $t = [System.IO.File]::ReadAllText((Join-Path $repo $rel), $utf8)
    Assert-That ($t -match 'Invoke-TestCaseSetup[^\r\n]*-Precondition') "$rel reicht precondition_sql an das setup durch"
}

if ($failed -eq 0) { Write-Host "case_teardown_test: alles gruen." -ForegroundColor Green } else { Write-Host "case_teardown_test: $failed Fehler." -ForegroundColor Red }
exit $failed
