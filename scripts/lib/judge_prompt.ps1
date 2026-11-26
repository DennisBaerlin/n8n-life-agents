#Requires -Version 5.1
# Judge-Prompt-Bausteine fuer scripts/judge_eval.ps1 (System- und User-Text). Eigene Datei, damit
# scripts/dev/judge_prompt_test.ps1 sie ohne API-Aufruf pruefen kann. Per Dot-Sourcing laden.
#
# Karten-Entscheid: Schreib-Werkzeuge halten hinter einer Bestaetigungs-Karte. Je nach Suite lehnt das Test-Telegram
# sie ab (n8n_test, orch_test, Durchspiel mit hitl: decline) oder nimmt sie an (Durchspiel mit hitl: approve). Der
# Judge muss wissen, welcher Fall vorlag, sonst haelt er "gebucht" nach einer angenommenen Karte fuer erfunden.
# Das Bundle-Feld card_decision traegt 'approved' oder 'declined'; fehlt es (aeltere Bundles, n8n_test, orch_test),
# gilt 'declined'.

function Get-JudgeCardDecision([object]$Entry) {
    if ($Entry -and "$($Entry.card_decision)" -eq 'approved') { return 'approved' }
    return 'declined'
}

function Get-JudgeSystemText([string]$CardDecision = 'declined') {
    $card = if ($CardDecision -eq 'approved') {
@'
- Jede Bestaetigungs-Karte eines Schreib-Werkzeugs wird im Test absichtlich ANGENOMMEN (CARD_DECISION: approved).
  Das Werkzeug fuehrt den Vorgang dann wirklich aus; der Test prueft den Datenbank-Zustand separat. Meldet der
  Agent danach, der Vorgang sei erledigt (gebucht, angelegt), ist das korrekt und NICHT erfunden; auch dann, wenn
  ACTUAL_TOOL_OUTPUT fehlt. Eine Abbruch-Meldung waere dagegen ein Fehler. Bewerte, ob Tool-Aufruf und Antwort
  zur Rubric passen.
'@
    } else {
@'
- Jede Bestaetigungs-Karte eines Schreib-Werkzeugs wird im Test absichtlich ABGELEHNT (CARD_DECISION: declined).
  Das Werkzeug meldet dann "abgebrochen" (cancelled). Meldet der Agent danach den Abbruch oder fragt, was er aendern
  soll, ist das korrekt. Bewerte, ob der Tool-Aufruf davor richtig war.
'@
    }
    $head = @'
Du bewertest, ob das Verhalten eines Agenten eine vorgegebene Erwartungs-Rubric erfuellt.
Beruecksichtige sowohl den Antworttext als auch den tatsaechlichen Tool-Aufruf inkl. seiner
Argumente; die eigentliche Entscheidung steht oft in ACTUAL_TOOL_INPUT.

So arbeitet das Testsystem (das ist KEIN Fehler des Agenten):
'@
    $tail = @'
- Schreib-Werkzeuge machen vor der Karte einen Probelauf in der Datenbank. ok:false (ohne Karte) heisst:
  die Datenbank hat den Vorgang sachlich abgelehnt; der Agent soll das sachlich melden, nichts erfinden.
- READ_TOOLS nennt die Lese-Aufrufe, READ_TOOL_OUTPUTS (kann fehlen) ihre gekuerzten Rueckgaben. Was dort steht,
  hat der Agent gelesen: Gibt er es wieder, ist es belegt, nicht erfunden. Ein fehlender Lese-Aufruf ist nie
  allein ein Grund fuer PARTIAL/FAIL. Die Werkzeuge loesen Namen selbst auf; ein Lese-Aufruf vorher ist kein Muss.
- ACTUAL_TOOL_OUTPUT ist die Rueckgabe des Werkzeugs (gekuerzt, kann fehlen). Was dort steht, darf der Agent
  sagen, auch wenn die Rubric es nicht nennt. Stehen in ACTUAL_TOOL_INPUT mehrere Aufrufe, ist der erste der aelteste.
- NEXT_STEP_BUTTON (kann fehlen) ist der Knopf, den das System unter die Antwort setzt, mit dem vom System gelieferten
  naechsten Schritt: nicht Teil des Antworttexts, kein stehengebliebener Platzhalter. Fehlt das Feld, gab es keinen Knopf.
- ANSWER_BUTTONS (kann fehlen) sind die Antwort-Knoepfe unter der Frage, vom Agenten als Markerzeile geschrieben und vom
  System als Knoepfe gezeigt: Teil der Frage, keine zweite Frage, kein Text zum Abtippen. Fehlt das Feld, gab es keine.
- Ein Berater-Werkzeug, das eine Themen-Karte vorschlaegt (tool_propose_plan_topics), zeigt dem Nutzer den Text als Karte
  mit Knoepfen; gespeichert wird erst beim Tipp. Eine leere Antwort direkt danach ist gewollt (die Karte spricht).
- CONFIRMATION_CARD (kann fehlen) ist die Bestaetigungs-Karte, die das System vor dem Schreiben zeigt. Das Werkzeug baut
  sie aus seinem Probelauf in der Datenbank, nicht der Agent: Ihre Knoepfe und Hinweise (Abbrechen, Bestaetigen, "Sag es
  mir einfach") sind keine Rueckfrage des Agenten, und ein Wert, den die Datenbank aufgeloest hat (z. B. "ich" als voller
  Name des Absenders), ist nicht erfunden. Die Antwort des Agenten steht nur in ACTUAL_OUTPUT.
- DB_CHECKS (kann fehlen) ist der Datenbank-Zustand nach der Runde, vom Test selbst gelesen (ok = erwarteter Wert gefunden).
  Im Durchspiel (Eintrag mit CONFIRMATION_CARD) sind ACTUAL_TOOL_INPUT und ACTUAL_TOOL_OUTPUT immer leer, weil der Test
  den Werkzeug-Aufruf nicht liest; Beleg fuer den Schreibvorgang sind dann die Karte mit CARD_DECISION und DB_CHECKS.
  Leere Werkzeug-Felder sind dort kein Grund fuer PARTIAL/FAIL.
- Zahlen, ids und Wahrheitswerte als Text ("1", "2.0", "true") sind gleichwertig zu Zahl/Boolean.
- Optionale Felder mit Datenbank-Standard (Datum = heute, Ordergebuehr = 0, Gueltig-ab = heute) darf der
  Agent leer lassen; "heute" ergibt ein leeres Datum. Ein ERFUNDENES anderes Datum ist dagegen falsch.
- Ein optionales Angebot ("wenn du magst, trage ich die IBAN nach") ist keine Rueckfrage; eine
  Rueckfrage, die den Vorgang blockiert, schon.
- Kann-Punkte der Rubric ('darf', 'may', 'is correct', 'passes', 'optional') sind nie Pflicht: ihr Fehlen ist
  kein Abzug. PARTIAL/FAIL nur fuer einen verletzten Muss- oder Verbots-Punkt. Was die Rubric weder verlangt noch
  verbietet (z. B. eine Folgefrage zum naechsten Schritt), ist kein Abzug.

Antworte AUSSCHLIESSLICH als JSON ohne Markdown-Fences in der Form:
{"verdict":"PASS|FAIL|PARTIAL","reason":"kurze Begruendung"}.
PASS nur, wenn die Rubric vollstaendig erfuellt ist; PARTIAL bei teilweiser Erfuellung; sonst FAIL.
'@
    return ($head.TrimEnd() + "`n" + $card.TrimEnd() + "`n" + $tail.TrimEnd() + "`n")
}

function Format-JudgeUserText([object]$Entry) {
    return @"
TASK:
$($Entry.task)

EXPECTED_BEHAVIOR (Rubric):
$($Entry.expected_behavior)

CARD_DECISION: $(Get-JudgeCardDecision $Entry)
ACTUAL_TOOL: $($Entry.actual_tool)
ACTUAL_TOOL_INPUT: $($Entry.actual_tool_input)
ACTUAL_TOOL_OUTPUT: $($Entry.actual_tool_output)
READ_TOOLS: $($Entry.read_tools)
$(if ($Entry.read_tool_outputs) { "READ_TOOL_OUTPUTS (what the agent read, oldest first, tool: output, shortened):`n$($Entry.read_tool_outputs)`n" })
$(if ($Entry.other_write_tools) { "OTHER_WRITE_TOOLS (further write tools called in the same run, oldest first, tool: output):`n$($Entry.other_write_tools)`n" })
$(if ($Entry.specialist_output) { "`nSPECIALIST_OUTPUT (the specialist's reply the orchestrator relayed):`n$($Entry.specialist_output)`n" })
$(if ($Entry.card_text) { "CONFIRMATION_CARD (card the system showed before the write, built by the tool from its database dry run, not written by the agent):`n$($Entry.card_text)`n" })
$(if ($Entry.db_checks) { "DB_CHECKS (database state the test read after the round, one check per line):`n$($Entry.db_checks)`n" })
$(if ($Entry.next_step_button) { "NEXT_STEP_BUTTON (button the system adds under the reply; the suggested next step):`n$($Entry.next_step_button)`n" })
$(if ($Entry.answer_buttons) { "ANSWER_BUTTONS (buttons the system shows under the question, written by the agent as its marker line):`n$($Entry.answer_buttons)`n" })
ACTUAL_OUTPUT:
$($Entry.actual_output)
"@
}
