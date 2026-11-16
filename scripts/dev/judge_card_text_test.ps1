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

Write-Host 'Aufgezeichnete Telegram-Anfragen einer Karten-Runde (Durchspiel s6 Runde 6, Gratis-Modus, Mock-Telegram-Log)'
# Wortlaut der Log-Zeilen (Get-MockTelegramRequests), Werte aus den erfundenen Test-Fixtures; Karte im Link-Modus (Resume-URL).
$recorded = @'
{"t":"2026-11-16T21:44:00.024Z","method":"sendMessageDraft","query":"","body":{"chat_id":"880055071","draft_id":1,"text":""}}
{"t":"2026-11-16T21:44:01.320Z","method":"sendMessage","query":"","body":{"chat_id":"880055001","text":"Neues Konto anlegen – bitte prüfen:\n\n• Name: \\_\\_E2E\\_\\_ Erlenbank Giro\n• Typ: Girokonto / Tagesgeld\n• Zeichen: 🏦\n• Bank: Erlenbank\n• IBAN / Kontonummer: DE89 3704 0044 0532 0130 00\n• Inhaber: Haushalt/gemeinsam\n• Saldo: 500,00 €\n• Stichtag: 29.02.2000\n• Zinsen: keine\n• Währung: EUR (Standard)\n\nAnderes Zeichen? Sag es mir einfach.\n\nZum Ändern abbrechen und neu schreiben.","disable_web_page_preview":true,"parse_mode":"Markdown","reply_markup":{"inline_keyboard":[[{"text":"❌ Abbrechen","url":"https://example.com/webhook-waiting/46/af3cd5d6-9a7e-5217-a8e3-7b21ce4cbf83?approved=false&signature=0369bf5beb21c12af5ef33ba1eaaa7ee69c569f0cd69cc6da55648e3550ab3bc"},{"text":"✅ Bestätigen","url":"https://example.com/webhook-waiting/46/af3cd5d6-9a7e-5217-a8e3-7b21ce4cbf83?approved=true&signature=06cb703056dbd3937ec40812de01cb83cd169bccf44354617ad05bf30c9eeaad"}]]}},"result_message_id":1007}
{"t":"2026-11-16T21:44:04.234Z","method":"sendMessage","query":"","body":{"chat_id":880055071,"text":"Das Konto __E2E__ Erlenbank Giro ist angelegt, Saldo 500,00 EUR.","disable_web_page_preview":true,"parse_mode":"HTML"},"result_message_id":1008}
'@
$reqs = @(foreach ($l in ($recorded -split "`n")) { if ($l.Trim()) { $l | ConvertFrom-Json } })
$conv = ConvertTo-BotOutputs $reqs
Check (@($conv.outputs).Count -eq 2 -and $conv.other -eq 1) 'zwei sichtbare Ausgaben, der Entwurf zaehlt nur als technischer Aufruf'
Check ((@($conv.outputs | Where-Object { $_.card })).Count -eq 1) 'Erkennung: genau eine Ausgabe ist die Karte (Resume-Link)'
$rs = Split-JudgeCardOutput $conv.outputs
Check ($rs.card -match 'Inhaber: Haushalt/gemeinsam' -and $rs.card -match 'Sag es mir einfach' -and $rs.card -match 'Abbrechen' -and $rs.card -match 'Bestätigen') 'aufgezeichnet: Karte (Felder, Hinweis, Knoepfe) in card'
Check ($rs.reply -eq 'Das Konto __E2E__ Erlenbank Giro ist angelegt, Saldo 500,00 EUR.') 'aufgezeichnet: nur die Antwort des Agenten in reply'
# Gegenprobe: dieselben Anfragen ohne Karten-Knoepfe -> keine Karte, alles ist Antwort.
$plain = @(foreach ($l in ($recorded -split "`n")) { if ($l.Trim()) { $o = $l | ConvertFrom-Json; $o.body.PSObject.Properties.Remove('reply_markup'); $o } })
$ps = Split-JudgeCardOutput (ConvertTo-BotOutputs $plain).outputs
Check ($ps.card -eq '' -and $ps.reply -match 'Inhaber: Haushalt/gemeinsam' -and $ps.reply -match 'angelegt') 'Gegenprobe ohne Karten-Knoepfe: card leer, alles in reply'
# Bestaetigen im Chat: Knoepfe mit callback_data nhitl1|<execId>|<a|d>|... (Form in test_n8n_state.ps1) statt Resume-Link.
$chat = @(foreach ($l in ($recorded -split "`n")) { if ($l.Trim()) { $o = $l | ConvertFrom-Json; if ($o.body.reply_markup) { $o.body.reply_markup = [pscustomobject]@{ inline_keyboard = @(,@([pscustomobject]@{ text = 'Abbrechen'; callback_data = 'nhitl1|46|d|x|ab12' }, [pscustomobject]@{ text = 'Bestaetigen'; callback_data = 'nhitl1|46|a|x|cd34' })) } }; $o } })
$cs = Split-JudgeCardOutput (ConvertTo-BotOutputs $chat).outputs
Check ($cs.card -match 'Inhaber: Haushalt/gemeinsam' -and $cs.reply -notmatch 'Inhaber') 'Karte mit Chat-Freigabe (nhitl1-Callback) wird ebenso erkannt'
$other = [pscustomobject]@{ method = 'sendMessage'; body = [pscustomobject]@{ chat_id = 1; text = 'Weiter?'; reply_markup = '{"inline_keyboard":[[{"text":"Ja","callback_data":"onboarding:finance:accounts"}]]}' } }
Check (-not (ConvertTo-BotOutputs @($other)).outputs[0].card) 'anderer Knopf (auch als JSON-String) ist keine Karte'

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

Write-Host 'Beleg des Schreibvorgangs im Durchspiel (DB-Pruefungen der Runde statt Werkzeug-Aufruf)'
# Form von $rd.sql_checks aus Invoke-Round (expect_sql nach der Runde).
$checks = @([pscustomobject]@{ sql = "SELECT count(*) FROM finance.accounts WHERE name = 'Beispielgiro';"; equals = '1'; got = '1'; ok = $true },
            [pscustomobject]@{ sql = 'SELECT balance FROM x;'; equals = '500.00'; got = '480.00'; ok = $false })
$dc = Format-JudgeDbChecks $checks
$dcl = @($dc -split "`n")
Check ($dcl.Count -eq 2 -and $dcl[0] -match '^ok: ' -and $dcl[0] -match "Beispielgiro" -and $dcl[0] -match '= 1$') 'DB-Pruefung erfuellt: eine Zeile mit ok, Abfrage und Wert'
Check ($dcl[1] -match '^FAIL: ' -and $dcl[1] -match '480\.00' -and $dcl[1] -match '500\.00') 'DB-Pruefung verfehlt: FAIL mit gefundenem und erwartetem Wert'
Check ((Format-JudgeDbChecks @()) -eq '') 'ohne DB-Pruefung leer'
$we = [pscustomobject]@{ task = 'x'; card_decision = 'approved'; card_text = 'Karte'; db_checks = $dc; actual_output = 'angelegt' }
$wut = Format-JudgeUserText $we
Check ($wut -match 'DB_CHECKS[^\n]*\nok: SELECT count') 'User-Text traegt DB_CHECKS'
Check ((Format-JudgeUserText ([pscustomobject]@{ task = 'x'; actual_output = 'a' })) -notmatch 'DB_CHECKS') 'ohne DB-Pruefungen kein Abschnitt'
$sa = Get-JudgeSystemText 'approved'
Check ($sa -match 'DB_CHECKS' -and $sa -match 'ACTUAL_TOOL_INPUT[^.]*leer') 'System-Text (approved): im Durchspiel darf ACTUAL_TOOL_INPUT leer sein, Beleg sind Karte und DB_CHECKS'
Check ((Get-JudgeSystemText 'declined') -match 'DB_CHECKS') 'System-Text (declined) erklaert DB_CHECKS ebenso'
Check ($sa -match 'weder verlangt noch\s+verbietet') 'System-Text: was die Rubric weder verlangt noch verbietet, ist kein Abzug'

Write-Host 'Verdrahtung im Durchspiel'
$conv = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\conversation_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Check ($conv -match 'lib\\judge_card_text\.ps1') 'Durchspiel laedt den Baustein'
Check ($conv -match 'card_text = \$split\.card' -and $conv -match 'actual_output = \$split\.reply') 'Buendel-Eintrag: card_text und actual_output getrennt'
Check ($conv -match 'db_checks = \(Format-JudgeDbChecks \$rd\.sql_checks\)') 'Buendel-Eintrag: db_checks aus den DB-Pruefungen der Runde'
Check ($conv -notmatch 'function (Get-OutputText|ConvertTo-BotOutputs|Get-ButtonList)\b' -and $conv -notmatch '\$VisibleMethods') 'Ausgabe-Umwandlung und Karten-Erkennung leben nur im Baustein (keine Kopie)'

if ($fail -eq 0) { Write-Host 'judge_card_text_test: alle Pruefungen bestanden.' -ForegroundColor Green }
else { Write-Host "judge_card_text_test: $fail Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $fail
