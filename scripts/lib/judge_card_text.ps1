#Requires -Version 5.1
# Bot-Ausgaben einer Durchspiel-Runde (Form von ConvertTo-BotOutputs in scripts/conversation_test.ps1) als Text fuer Pruefungen und
# Bewerter-Buendel. Die Bestaetigungs-Karte baut das Werkzeug aus seinem Probelauf, nicht der Agent; im Buendel steht sie darum
# getrennt (card_text -> Abschnitt CONFIRMATION_CARD, scripts/lib/judge_prompt.ps1). Sonst liest der Bewerter Karten-Knoepfe als
# erneute Rueckfrage und einen von der Datenbank aufgeloesten Namen als erfunden. Per Dot-Sourcing laden;
# Selbsttest scripts/dev/judge_card_text_test.ps1.

# Alle Texte und Knopf-Beschriftungen, Karten eingeschlossen (expect/forbid pruefen, was die Person sieht).
function Get-OutputText($Outs) {
    (@(foreach ($o in $Outs) { $o.text; foreach ($b in $o.buttons) { $b.label } }) | Where-Object { $_ }) -join "`n"
}

# Rueckgabe @{ reply; card }: reply = Ausgaben ohne Karte (die Antwort des Agenten), card = nur die Karten (Feld card = true).
function Split-JudgeCardOutput($Outs) {
    $cards = @($Outs | Where-Object { $_.card }); $rest = @($Outs | Where-Object { -not $_.card })
    return @{ reply = (Get-OutputText $rest); card = (Get-OutputText $cards) }
}