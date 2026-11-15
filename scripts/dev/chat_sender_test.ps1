#Requires -Version 5.1
# Selbsttest der Absender-Aufloesung von n8n_test (Resolve-TestCaseChatId, Get-TestSenderPairingSql in dev/test_n8n_state.ps1). Kein Substrat, keine Kosten.
# Der Fehler, den er festhaelt: n8n_test setzte jede chat_id auf den Owner, ein Mitglieds-Fall pruefte still den Owner.
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
Assert-That ($drv -notmatch '\[long\]\$chatId\s*=\s*\$TestOwnerTelegramUid') 'n8n_test setzt die chat_id nicht mehr fest auf den Owner'

if ($failed -eq 0) { Write-Host "chat_sender_test: alles gruen." -ForegroundColor Green } else { Write-Host "chat_sender_test: $failed Fehler." -ForegroundColor Red }
exit $failed
