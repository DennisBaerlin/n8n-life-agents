#Requires -Version 5.1
# Selbsttest der Laien-Messung (scripts/lib/lay_metrics.ps1): je Regel ein verletzender Fall, der gemeldet werden muss, und ein
# erlaubter Fall, der still bleiben muss. Aufgezeichnete Runden in der Form von ConvertTo-BotOutputs, alle Texte erfunden.
# Kein Docker, kein Netz. Exit-Code = Anzahl Fehler.
# Usage:  .\scripts\dev\lay_metrics_test.ps1 [-Verbose]   (-Verbose zeigt auch die gruenen Faelle)
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\lay_metrics.ps1')

$script:fails = 0; $script:count = 0
function Expect([string]$Name, $Findings, [string[]]$Rules) {
    $script:count++
    $got = @($Findings | Where-Object { $_ } | ForEach-Object { $_.rule } | Sort-Object -Unique) -join ','
    $want = @($Rules | Where-Object { $_ } | Sort-Object -Unique) -join ','
    if ($got -ne $want) {
        Write-Host "  [FAIL] ${Name}: erwartet '$want', gemeldet '$got'" -ForegroundColor Red
        foreach ($f in @($Findings | Where-Object { $_ })) { Write-Host "         $($f.rule): $($f.detail) | $($f.excerpt)" -ForegroundColor DarkGray }
        $script:fails++
    } elseif ($Verbose) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
}
function Msg([string]$Text, [string[]]$Buttons = @(), [switch]$Card, [string]$Method = 'sendMessage') {
    return [pscustomobject]@{ method = $Method; text = $Text; card = [bool]$Card
        buttons = @($Buttons | ForEach-Object { [pscustomobject]@{ label = $_; target = 'cb:x' } }) }
}
function Prior([string]$UserInput, $Outputs, [string]$CardDecision = 'abgelehnt') {
    return [pscustomobject]@{ input = $UserInput; outputs = @($Outputs); card_decision = $CardDecision }
}

# --- L1: hoechstens eine Frage je Nachricht ---
Expect 'L1 zwei Fragen' (Measure-BotOutput -Outputs @((Msg 'Wie hoch ist dein Gehalt? Und wann kommt es?'))) @('L1')
Expect 'L1 eine Frage' (Measure-BotOutput -Outputs @((Msg 'Danke. Wann kommt das Gehalt?'))) @()
Expect 'L1 zwei Satzzeichen hintereinander sind eine Frage' (Measure-BotOutput -Outputs @((Msg 'Wirklich??'))) @()
Expect 'L1 Beispiele in Anfuehrungszeichen zaehlen nicht' (Measure-BotOutput -Outputs @((Msg @'
Frag mich zum Beispiel „Wie viel habe ich?“ oder “Was kostet das?”. Womit soll ich anfangen?
'@))) @()
Expect 'L1 Fragezeichen in einer Adresse zaehlt nicht' (Measure-BotOutput -Outputs @((Msg 'Hier: https://example.org/a?x=1 Passt das?'))) @()
Expect 'L1 auch auf Karten' (Measure-BotOutput -Outputs @((Msg 'Eintragen? Oder lieber nicht?' @('Ja', 'Nein') -Card))) @('L1')
Expect 'L1 koreanisches Fragezeichen' (Measure-BotOutput -Outputs @((Msg '월급은 얼마예요？ 언제 들어와요？'))) @('L1')

# --- L2: Gespraechstext hoechstens 600 Zeichen, nach einer Karte hoechstens ein Satz ---
$long = ('Das ist ein erfundener Satz. ' * 25).Trim()
$ok600 = ('x' * 599) + '.'
Expect 'L2 zu lang' (Measure-BotOutput -Outputs @((Msg $long))) @('L2')
Expect 'L2 genau 600 Zeichen' (Measure-BotOutput -Outputs @((Msg $ok600))) @()
Expect 'L2 Datenzeilen zaehlen nicht mit' (Measure-BotOutput -Outputs @((Msg ("Deine Konten:`n" + (("• Konto Beispiel mit einem langen Namen: 100,00 EUR`n") * 20))))) @()
Expect 'L2 lange Karte ist erlaubt' (Measure-BotOutput -Outputs @((Msg $long @('Ja', 'Nein') -Card))) @()
$card = Msg 'Dauerauftrag ändern – bitte prüfen:' @('Bestätigen', 'Abbrechen') -Card
Expect 'L2 zwei Saetze nach einer Karte' (Measure-BotOutput -Outputs @($card, (Msg 'Ist gebucht. Als Nächstes kommt der Notgroschen.'))) @('L2')
Expect 'L2 ein Satz nach einer Karte' (Measure-BotOutput -Outputs @($card, (Msg 'Der Dauerauftrag steht jetzt auf dem 1. des Monats (ab 1.3.).'))) @()
Expect 'L2 Abkuerzung trennt keinen Satz' (Measure-BotOutput -Outputs @($card, (Msg 'Das gilt z. B. auch für den Rest.'))) @()
Expect 'L2 Liste nach einer Karte ist kein Gespraechstext' (Measure-BotOutput -Outputs @($card, (Msg "Das stellst du bei deiner Bank ein:`n• Rate A: 100 EUR`n• Rate B: 200 EUR`nDanach ist alles fertig."))) @()
Expect 'L2 vor der Karte duerfen es zwei Saetze sein' (Measure-BotOutput -Outputs @((Msg 'Ich trage das ein. Prüfe kurz die Karte.'), $card)) @()
Expect 'L2 Knopf-Quittung ist kein Gespraechstext' (Measure-BotOutput -Outputs @($card, (Msg 'Gespeichert. Danke.' -Method 'answerCallbackQuery'))) @()

$menu = "✅ Haushalt ist eingerichtet.`n`nDein Stand – 1 von 3 erledigt`n`n✅ Haushalt`n◻ Beispielbereich (0/7)`n`n👉 Als Nächstes: Konten`nTippe auf Weiter, um loszulegen."
Expect 'L2 System-Uebersicht mit Statuszeilen nach einer Karte' (Measure-BotOutput -Outputs @($card, (Msg $menu @('Weiter')))) @()
$oneItem = "Das stellst du bei deiner Beispielbank ein:`n`n1. Dauerauftrag Beispielmiete einrichten: 200,00 € monatlich.`n`nTippe, wenn alles eingerichtet ist."
Expect 'L2 System-Liste mit einem Punkt und Knopf nach einer Karte' (Measure-BotOutput -Outputs @($card, (Msg $oneItem @('Erledigt')))) @()
Expect 'L2 dieselbe Form ohne Knopf zaehlt als Gespraech' (Measure-BotOutput -Outputs @($card, (Msg $oneItem))) @('L2')
Expect 'L2 Haken oder Zeigefinger am Anfang machen mit Knopf keine Liste' (Measure-BotOutput -Outputs @($card, (Msg '✅ Das ist gebucht. Weiter geht es mit dem Notgroschen.' @('Weiter')))) @('L2')
Expect 'L2 Zwischenzeile mit Zeichen ist kein Listenpunkt' (Measure-BotOutput -Outputs @($card, (Msg "Das ist gebucht.`n👉 Weiter geht es mit dem Notgroschen. Tippe unten." @('Weiter')))) @('L2')
Expect 'L2 Strich in der ersten Zeile ist keine Systemliste' (Measure-BotOutput -Outputs @($card, (Msg '- Das ist gebucht. Weiter geht es mit dem Notgroschen.' @('Weiter')))) @('L2')
Expect 'L2 Saetze mit Knopf ohne Listenzeile bleiben Gespraech'(Measure-BotOutput -Outputs @($card, (Msg 'Das ist gebucht. Weiter geht es mit dem Notgroschen.' @('Weiter')))) @('L2')
Expect 'L2 ein Datum am Zeilenanfang ist keine Liste' (Measure-BotOutput -Outputs @($card, (Msg "1. März geht die erste Rate raus. Danach jeden Monat. Alles ist fertig."))) @('L2')
Expect 'L2 eine einzelne Listenzeile macht aus Saetzen keine Liste' (Measure-BotOutput -Outputs @($card, (Msg "Das ist gebucht. Als Nächstes kommt das:`n• Notgroschen"))) @('L2')
foreach ($t in @('3 % p. a. sind jetzt hinterlegt.', 'Konto, Karte usw. sind angelegt.', 'Die Rate ist mtl. eingetragen.',
                 'Dr. Beispiel ist als Praxis hinterlegt.', 'Der Betrag steht p. M. im Plan, vgl. den Abschnitt monatl. Kosten.')) {
    Expect "L2 Abkuerzung: $t" (Measure-BotOutput -Outputs @($card, (Msg $t))) @()
}

# --- L3: Wahl nur als Knoepfe ---
$choice = "Zwei Wege:`n1. Höhere Rate bis Sommer`n2. Gleiche Rate, länger`nWelchen nimmst du?"
Expect 'L3 nummerierte Wege ohne Knoepfe' (Measure-BotOutput -Outputs @((Msg $choice))) @('L3')
Expect 'L3 dieselbe Wahl mit Knoepfen' (Measure-BotOutput -Outputs @((Msg $choice @('Höhere Rate (empfohlen)', 'Länger')))) @()
Expect 'L3 Schritte ohne Frage' (Measure-BotOutput -Outputs @((Msg "So geht es:`n1. App öffnen`n2. Auszug laden"))) @()
Expect 'L3 Anleitung mit Rueckfrage ist keine Wahl' (Measure-BotOutput -Outputs @((Msg "So geht es:`n1. App öffnen`n2. Auszug laden`nKlappt das?"))) @()
Expect 'L3 Varianten ohne Wahlwort in der Frage' (Measure-BotOutput -Outputs @((Msg "Zwei Varianten:`n1. Höhere Rate`n2. Länger sparen`nWie siehst du das?"))) @('L3')
Expect 'L3 Antworte mit 1 oder 2'(Measure-BotOutput -Outputs @((Msg "1) Höhere Rate`n2) Länger sparen`nAntworte mit 1 oder 2."))) @('L3')
Expect 'L3 Weg 1 und Weg 2 im Fliesstext' (Measure-BotOutput -Outputs @((Msg 'Weg 1 wäre eine höhere Rate, Weg 2 ein späteres Datum. Was passt dir?'))) @('L3')
Expect 'L3 ein Datum am Zeilenanfang ist keine Liste' (Measure-BotOutput -Outputs @((Msg "1. März geht die Rate raus.`nPasst das?"))) @()

# --- L9: nichts doppelt ---
$list = "Noch einzutragen:`n• Sparziel Beispielreise`n• Dauerauftrag Beispielmiete`nJetzt eintragen oder später ansehen."
Expect 'L9 dieselbe Nachricht zweimal in einer Runde' (Measure-BotOutput -Outputs @((Msg 'Deine Liste steht bereit.'), (Msg 'Deine Liste steht bereit.'))) @('L9')
Expect 'L9 Hinweis an zwei Stellen (Karte und Text)' (Measure-BotOutput -Outputs @((Msg "Eintrag prüfen:`nDas stellst du bei deiner Beispielbank selbst als Dauerauftrag ein." @('Bestätigen', 'Abbrechen') -Card), (Msg 'Das stellst du bei deiner Beispielbank selbst als Dauerauftrag ein.'))) @('L9')
Expect 'L9 Kurzzeile auf zwei Karten ist gewollt' (Measure-BotOutput -Outputs @((Msg "Eintrag A:`nDas stellst du bei deiner Bank selbst ein. Es kommt auf deine Bank-Liste." @('Ja') -Card), (Msg "Eintrag B:`nDas stellst du bei deiner Bank selbst ein. Es kommt auf deine Bank-Liste." @('Ja') -Card))) @()
Expect 'L9 Liste zum zweiten Mal in spaeterer Runde' (Measure-BotOutput -Outputs @((Msg $list @('Jetzt eintragen'))) -UserInput 'und jetzt' -History @((Prior 'zeig die Liste' @((Msg $list @('Jetzt eintragen')))))) @('L9')
Expect 'L9 gleiche Anfrage darf dieselbe Liste bekommen' (Measure-BotOutput -Outputs @((Msg $list)) -UserInput '/liste' -History @((Prior '/liste' @((Msg $list))))) @()
Expect 'L9 kurze Antwort darf sich wiederholen' (Measure-BotOutput -Outputs @((Msg 'Alles klar.')) -UserInput 'danke' -History @((Prior 'ok' @((Msg 'Alles klar.'))))) @()
$entry = Msg "Dauerauftrag ändern – bitte prüfen:`nName: Beispielmiete`nBetrag: 500,00 EUR" @('Bestätigen', 'Abbrechen') -Card
Expect 'L9 angenommene Karte kommt wieder' (Measure-BotOutput -Outputs @($entry) -UserInput 'weiter' -History @((Prior 'los' @($entry) 'angenommen'))) @('L9')
Expect 'L9 abgelehnte Karte darf wiederkommen' (Measure-BotOutput -Outputs @($entry) -UserInput 'doch' -History @((Prior 'los' @($entry) 'abgelehnt'))) @()
Expect 'L9 dieselbe Karte zweimal in einer Runde' (Measure-BotOutput -Outputs @($entry, $entry)) @('L9')

# --- L12: keine Merkarbeit ---
$l12 = @(
    'Merk dir bitte den Termin.', 'Merke dir das für später.', 'Bitte merken Sie sich das Datum.', 'Sag mir dann Bescheid.',
    'Gib mir Bescheid, wenn das Geld da ist.', 'Denk daran, die Rate zu ändern.', 'Vergiss nicht, den Vertrag zu kündigen.',
    'Erinnere mich im Mai daran.', 'Melde dich dann wieder bei mir.', 'Behalte das im Hinterkopf.', 'Schreib es dir am besten auf.',
    "Don't forget to move the money.", 'Remember to check it in May.', 'Let me know when it arrives.', 'Keep that in mind.',
    '날짜를 꼭 기억해 두세요.', '잊지 마세요.'
)
foreach ($t in $l12) { Expect "L12 Merkarbeit: $t" (Measure-BotOutput -Outputs @((Msg $t))) @('L12') }
$l12ok = @(
    'Ich sage dir Bescheid, sobald es losgehen kann.', 'Ich merke mir das für dich.', 'Du bekommst Bescheid, sobald es bestätigt ist.',
    'Ich erinnere dich am 3. Mai.', "I'll remember to remind you.", '제가 기억해 둘게요.',
    'Ich merke dir den Termin vor.', 'Ich behalte das im Hinterkopf.', "I$([char]0x2019)ll remember to remind you.", "I'll keep that in mind.",
    "I'll make a note.", 'Ich notiere dir das im Plan.', 'Dann sag ich Bescheid, wenn es soweit ist.',
    'Frag zum Beispiel „Erinnere mich am Freitag an die Miete“.'
)
foreach ($t in $l12ok) { Expect "L12 erlaubt: $t" (Measure-BotOutput -Outputs @((Msg $t))) @() }
Expect 'L12 auch auf der Karte' (Measure-BotOutput -Outputs @((Msg "Bleibt offen: bitte denk selbst daran." @('Ja') -Card))) @('L12')

# --- Einzeltext (mock_lint) ---
Expect 'Text: Markerzeilen sind kein Text, CHOICES zaehlt als Knoepfe' (Measure-BotText -Text "Zwei Wege:`n1. Höhere Rate`n2. Länger`nWelchen nimmst du?`nCHOICES Höhere Rate | Länger") @()
Expect 'Text: NEXT_STEP wird nicht mitgezaehlt' (Measure-BotText -Text "$ok600`nNEXT_STEP") @()
Expect 'Text: Wahl ohne Knoepfe' (Measure-BotText -Text $choice) @('L3')
Expect 'Text: zwei Fragen und Merkarbeit' (Measure-BotText -Text 'Passt das? Oder anders? Merk dir den Tag.') @('L1', 'L12')
$json = '{"is_statement":true,"note":"' + ('erfunden ' * 90) + '?? merk dir"}'
Expect 'Text: reine Daten (JSON) sind keine Nachricht' (Measure-BotText -Text $json) @()
Expect 'Text: Klammer am Anfang ohne JSON bleibt Text' (Measure-BotText -Text '[Hinweis] Passt das? Oder anders?') @('L1')
Expect 'Text: derselbe Satz zweimal'(Measure-BotText -Text "Das stellst du bei deiner Beispielbank selbst als Dauerauftrag ein.`nDas stellst du bei deiner Beispielbank selbst als Dauerauftrag ein.") @('L9')

# --- Befund traegt, was die Aufzeichnung braucht ---
$f = @(Measure-BotOutput -Outputs @((Msg $long)))
$script:count++
if ($f.Count -ne 1 -or -not $f[0].detail -or -not $f[0].excerpt -or $f[0].excerpt.Length -gt 80) { Write-Host '  [FAIL] Befund: detail/excerpt (hoechstens 80 Zeichen) fehlt' -ForegroundColor Red; $script:fails++ }

$color = if ($script:fails) { 'Red' } else { 'Green' }
Write-Host "lay_metrics_test: $($script:count - $script:fails)/$($script:count) bestanden" -ForegroundColor $color
exit $script:fails
