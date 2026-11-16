#Requires -Version 5.1
# Selbsttest: Im Bewerter-Buendel des Durchspiels stehen Bestaetigungs-Karte und Agenten-Antwort getrennt
# (scripts/lib/judge_card_text.ps1, Abschnitt CONFIRMATION_CARD in scripts/lib/judge_prompt.ps1). Ohne Trennung las der
# Bewerter den Karten-Text als Antwort: Karten-Knoepfe wurden zur erneuten Rueckfrage, ein von der Datenbank aufgeloester
# Inhaber-Name zum erfundenen Wert. Kein Substrat, kein API-Aufruf, keine Kosten.
# Usage:  .\scripts\dev\judge_card_text_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$fail = 0
function Check([bool]$Ok, [string]$Msg) {
    if ($Ok) { Write-Host "[PASS] $Msg" -ForegroundColor Green }
    else { Write-Host "[FAIL] $Msg" -ForegroundColor Red; $script:fail++ }
}
$lib = Join-Path $repo 'scripts\lib\judge_card_text.ps1'
. $lib
. (Join-Path $repo 'scripts\lib\judge_prompt.ps1')

# Ausgaben einer Runde in der Form von ConvertTo-BotOutputs (conversation_test): erst die Karte, dann die Antwort nach dem Tipp.
$cardOut = [pscustomobject]@{ method = 'sendMessage'; text = "Neues Konto anlegen - bitte pruefen:`n- Inhaber: Erika Beispiel`n`nZum Aendern abbrechen und neu schreiben."
    buttons = @([pscustomobject]@{ label = 'Abbrechen'; target = 'cb:nhitl1|n' }, [pscustomobject]@{ label = 'Bestaetigen'; target = 'cb:nhitl1|y' }); card = $true }
$reaction = [pscustomobject]@{ method = 'setMessageReaction'; text = ''; buttons = @(); card = $false }
$reply = [pscustomobject]@{ method = 'sendMessage'; text = 'Das Konto Beispielgiro ist angelegt. Gibt es noch ein Konto?'
    buttons = @([pscustomobject]@{ label = 'Weiter'; target = 'cb:x' }); card = $false }
$outs = @($cardOut, $reaction, $reply)

Write-Host 'Trennen von Karte und Antwort'
$all = Get-OutputText $outs
Check ($all -match 'Inhaber: Erika Beispiel' -and $all -match 'angelegt') 'Get-OutputText (Pruefungen expect/forbid) sieht weiter alles'
$sp = Split-JudgeCardOutput $outs
Check ($sp.reply -match 'angelegt' -and $sp.reply -match 'Weiter') 'Antwort: Text und Knoepfe der Nicht-Karten-Ausgaben'
Check ($sp.reply -notmatch 'Inhaber' -and $sp.reply -notmatch 'Bestaetigen') 'Antwort enthaelt nichts von der Karte'
Check ($sp.card -match 'Inhaber: Erika Beispiel' -and $sp.card -match 'Abbrechen' -and $sp.card -match 'Bestaetigen') 'Karte: Text und Knoepfe der Karte'
Check ($sp.card -notmatch 'angelegt') 'Karte enthaelt nichts von der Antwort'
$none = Split-JudgeCardOutput @($reply)
Check ($none.card -eq '' -and $none.reply -match 'angelegt') 'ohne Karte: card leer, Antwort vollstaendig'

Write-Host 'Judge-Prompt'
$entry = [pscustomobject]@{ task = 'x'; expected_behavior = 'y'; card_decision = 'approved'; card_text = $sp.card; actual_output = $sp.reply }
$ut = Format-JudgeUserText $entry
$iCard = $ut.IndexOf('CONFIRMATION_CARD'); $iOut = $ut.IndexOf('ACTUAL_OUTPUT:')
Check ($iCard -ge 0 -and $iOut -gt $iCard) 'User-Text: Abschnitt CONFIRMATION_CARD vor ACTUAL_OUTPUT'
Check ($ut.Substring($iOut) -notmatch 'Inhaber' -and $ut.Substring($iCard, $iOut - $iCard) -match 'Inhaber: Erika Beispiel') 'Karten-Text nur im Karten-Abschnitt, nicht in der Antwort'
Check ((Format-JudgeUserText ([pscustomobject]@{ task = 'x'; actual_output = 'a' })) -notmatch 'CONFIRMATION_CARD') 'ohne Karte kein Abschnitt'
foreach ($d in 'declined', 'approved') {
    $st = Get-JudgeSystemText $d
    Check ($st -match 'CONFIRMATION_CARD' -and $st -match 'keine Rueckfrage des Agenten' -and $st -match 'aufgeloest') "System-Text ($d) erklaert die Karte: Knoepfe keine Rueckfrage, aufgeloeste Werte nicht erfunden"
}

Write-Host 'Verdrahtung im Durchspiel'
$conv = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\conversation_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Check ($conv -match 'lib\\judge_card_text\.ps1') 'Durchspiel laedt den Baustein'
Check ($conv -match 'card_text = \$split\.card' -and $conv -match 'actual_output = \$split\.reply') 'Buendel-Eintrag: card_text und actual_output getrennt'
Check ($conv -notmatch 'function Get-OutputText') 'Get-OutputText lebt nur im Baustein (keine Kopie)'

if ($fail -eq 0) { Write-Host 'judge_card_text_test: alle Pruefungen bestanden.' -ForegroundColor Green }
else { Write-Host "judge_card_text_test: $fail Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $fail
