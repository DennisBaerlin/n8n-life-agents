#Requires -Version 5.1
# Selbsttest der Absender-Aufloesung von n8n_test (Resolve-TestCaseChatId, Get-TestSenderPairingSql in dev/test_n8n_state.ps1). Kein Substrat, keine Kosten.
# Haelt fest: n8n_test loest die chat_id je Fall auf (numerisch = diese uid, sonst Owner); ein Mitglieds-Fall darf nicht still als Owner laufen.
# Prueft ausserdem die Wahl des Agent-Knotens, der lief (Resolve-AgentNodeName, Get-AgentOutput), und die Verdrahtung in n8n_test und mock_route_test.
# Usage:  .\scripts\dev\chat_sender_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'test_n8n_state.ps1')
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
function Get-Chat([string]$Json) { Resolve-TestCaseChatId -Case ($Json | ConvertFrom-Json) }
$owner = [long]$script:TestOwnerTelegramUid

Write-Host "Aufloesung der chat_id"
Assert-That ((Get-Chat '{"id":"a","chat_id":"880055200"}') -eq 880055200) 'numerischer String = diese uid (Mitglied)'
Assert-That ((Get-Chat '{"id":"a","chat_id":880055201}') -eq 880055201) 'Zahl = diese uid'
Assert-That ((Get-Chat '{"id":"a","chat_id":"test_ac01"}') -eq $owner) "nicht numerisch ('test_ac01') = Owner"
Assert-That ((Get-Chat '{"id":"a"}') -eq $owner) 'ohne chat_id = Owner'
Assert-That ((Get-Chat '{"id":"a","chat_id":""}') -eq $owner) 'leere chat_id = Owner'

Write-Host "Pairing-SQL"
$lena = Get-TestSenderPairingSql -ChatId 880055200
Assert-That ($lena -match "'person_id' = 'lena' THEN p \|\| jsonb_build_object\('telegram_user_id', 880055200::bigint\)") 'Lena bekommt ihre uid'
Assert-That ($lena -match "'person_id' = 'lisa' THEN p - 'telegram_user_id'") 'Lisa verliert ihre uid'
Assert-That ($lena -match "'person_id' = 'owner' THEN p \|\| jsonb_build_object\('telegram_user_id', ${owner}::bigint\)") 'Owner bleibt gepairt'
$own = Get-TestSenderPairingSql -ChatId $owner
Assert-That (($own -match "'person_id' = 'lena' THEN p - 'telegram_user_id'") -and ($own -match "'person_id' = 'lisa' THEN p - 'telegram_user_id'")) 'Absender Owner entfernt die uid von Lena und Lisa (kein Mitglied bleibt gepairt)'
$lisa = Get-TestSenderPairingSql -ChatId 880055201
Assert-That ($lisa -match "'person_id' = 'lisa' THEN p \|\| jsonb_build_object\('telegram_user_id', 880055201::bigint\)") 'Lisa (Kind) bekommt ihre uid'

Write-Host "Verdrahtung"
$drv = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\n8n_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($drv -match 'Resolve-TestCaseChatId \$tc' -and $drv -match 'Set-TestSenderPairing') 'n8n_test loest die chat_id des Falls auf und paart den Absender'
Assert-That ($drv -notmatch '\[long\]\$chatId\s*=\s*\$TestOwnerTelegramUid') 'n8n_test setzt die chat_id nicht fest auf den Owner'
Write-Host "Agent-Knoten, der lief (Guide: Kind laeuft ueber 'Guide Agent (personal)')"
$names = @('Guide Agent', 'Guide Agent (personal)')
$rdChild = '{ "Household status read": [ {} ], "Guide Agent (personal)": [ { "data": { "main": [ [ { "json": { "output": "Du kannst mich fragen: wie es funktioniert." } } ] ] } } ] }' | ConvertFrom-Json
$rdOwner = '{ "Guide Agent": [ { "data": { "main": [ [ { "json": { "output": "Antwort Owner" } } ] ] } } ] }' | ConvertFrom-Json
$nodeChild = Resolve-AgentNodeName $rdChild $names
Assert-That ($nodeChild -eq 'Guide Agent (personal)') 'Kind: der Knoten, der lief, wird gewaehlt'
Assert-That ((Get-AgentOutput $rdChild $nodeChild) -eq 'Du kannst mich fragen: wie es funktioniert.') 'Kind: die Antwort des Knotens, der lief, kommt im Buendel an'
Assert-That ((Get-AgentOutput $rdChild $names[0]) -eq '') 'Gegenprobe: der erste Knoten allein liefert fuer das Kind nichts'
Assert-That ((Resolve-AgentNodeName $rdOwner $names) -eq 'Guide Agent') 'Owner: erster Knoten'
Assert-That ((Resolve-AgentNodeName ('{}' | ConvertFrom-Json) $names) -eq 'Guide Agent') 'kein Knoten gelaufen: erster Kandidat'
$drv2 = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\n8n_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($drv2 -match 'Resolve-AgentNodeName \$runData \$AgentNodeNames') 'n8n_test waehlt den Agent-Knoten je Fall'
$mrt = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\dev\mock_route_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($mrt -match "Get-TestSenderRole" -and $mrt -match "Household status read") 'mock_route_test belegt im Agenten die Rolle des Absenders (Knoten Household status read)'
Assert-That ($lisa -match "880055201" -and $script:TestSenderUids['880055201'] -eq 'lisa') 'gc13: die id des Kind-Falls gehoert der Fixture-Person lisa'
$gc13 = ([System.IO.File]::ReadAllText((Join-Path $repo 'tests\agent\core\guide_cases.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json) | Where-Object { $_.id -eq 'gc13' }
Assert-That ($gc13 -and "$($gc13.chat_id)" -eq '880055201') 'gc13 laeuft mit der Kind-id'

if ($failed -eq 0) { Write-Host "chat_sender_test: alles gruen." -ForegroundColor Green } else { Write-Host "chat_sender_test: $failed Fehler." -ForegroundColor Red }
exit $failed
