#Requires -Version 5.1
# Selbsttest der Berater-Markerzeile CHOICES im Direkt-Test (scripts/lib/choices_marker.ps1). Kein Substrat, keine Kosten.
# Haelt fest: Der Direkt-Test nimmt die Zeile wie der Relay aus dem Agententext und gibt die Optionen als Knoepfe an den Bewerter;
# ungueltige Zeilen verschwinden ohne Knoepfe (nie roh beim Nutzer).
# Usage:  .\scripts\dev\choices_marker_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\choices_marker.ps1')
. (Join-Path $repo 'scripts\lib\judge_prompt.ps1')
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}

Write-Host "Trennen der Markerzeile"
$s = Split-ChoicesMarker "Welches Ziel soll gelten?`nCHOICES 3 Monate (empfohlen) | 6 Monate | Anders"
Assert-That ($s.text -eq 'Welches Ziel soll gelten?' -and $s.options.Count -eq 3 -and $s.options[0] -eq '3 Monate (empfohlen)') 'letzte Zeile: drei Knoepfe, Empfehlung zuerst, Text ohne Zeile'
$s = Split-ChoicesMarker "Los?`r`nCHOICES Los geht's | Später`r`n"
Assert-That ($s.text -eq 'Los?' -and $s.options.Count -eq 2 -and $s.options[1] -eq 'Später') 'CRLF, Umlaut, Apostroph, Leerzeile am Ende'
$s = Split-ChoicesMarker "Frage?`nCHOICES nur eine"
Assert-That ($s.text -eq 'Frage?' -and $s.options.Count -eq 0) 'eine Option: Zeile weg, keine Knoepfe'
$s = Split-ChoicesMarker "Frage?`nCHOICES a | b | c | d"
Assert-That ($s.options.Count -eq 0) 'vier Optionen: keine Knoepfe'
$s = Split-ChoicesMarker "Frage?`nCHOICES Das ist eine viel zu lange Option | Nein"
Assert-That ($s.options.Count -eq 0) 'Option ueber 24 Zeichen: keine Knoepfe'
$s = Split-ChoicesMarker "Frage?`nCHOICES https://x.example | Nein"
Assert-That ($s.options.Count -eq 0) 'Link in einer Option: keine Knoepfe'
$s = Split-ChoicesMarker "CHOICES Ja | Nein`nNoch ein Satz danach."
Assert-That ($s.text -eq 'Noch ein Satz danach.' -and $s.options.Count -eq 0) 'nicht letzte Zeile: Zeile weg, keine Knoepfe'
$s = Split-ChoicesMarker 'Die CHOICES im Satz bleiben stehen.'
Assert-That ($s.text -eq 'Die CHOICES im Satz bleiben stehen.' -and $s.options.Count -eq 0) 'nur eine Zeile am Zeilenanfang ist der Marker'
$s = Split-ChoicesMarker "Frage?`nCHOICES: Ja | Nein"
Assert-That ($s.text -eq 'Frage?' -and $s.options.Count -eq 2) 'CHOICES mit Doppelpunkt: Knoepfe'
$s = Split-ChoicesMarker "Frage?`n**CHOICES** Ja | Nein"
Assert-That ($s.text -eq 'Frage?' -and $s.options.Count -eq 2) 'fett gesetztes CHOICES: Knoepfe'
$s = Split-ChoicesMarker "Frage?`nChoices Ja | Nein"
Assert-That ($s.text -eq 'Frage?' -and $s.options.Count -eq 2) 'Choices in Gross-/Kleinschreibung: Knoepfe'
$s = Split-ChoicesMarker 'Choices sind wichtig, sagt man.'
Assert-That ($s.text -eq 'Choices sind wichtig, sagt man.' -and $s.options.Count -eq 0) 'ein Satz, der mit Choices beginnt (ohne Trennstrich), bleibt stehen'
$s = Split-ChoicesMarker ''
Assert-That ($s.text -eq '' -and $s.options.Count -eq 0) 'leerer Text'

Write-Host "Judge-Prompt"
$with = [pscustomobject]@{ task = 'x'; actual_output = 'Frage?'; answer_buttons = '[Ja] [Nein]' }
Assert-That ((Format-JudgeUserText $with) -match 'ANSWER_BUTTONS[^\n]*\n\[Ja\] \[Nein\]\n') 'User-Text traegt die Knoepfe'
Assert-That ((Format-JudgeUserText ([pscustomobject]@{ task = 'x'; actual_output = 'Antwort' })) -notmatch 'ANSWER_BUTTONS') 'ohne Knoepfe kein Abschnitt'
Assert-That ((Get-JudgeSystemText) -match 'ANSWER_BUTTONS' -and (Get-JudgeSystemText 'approved') -match 'ANSWER_BUTTONS') 'System-Text erklaert das Feld in beiden Fassungen'
$nt = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\n8n_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($nt -match 'Split-ChoicesMarker' -and $nt -match 'answer_buttons = ') 'n8n_test trennt die Zeile und schreibt answer_buttons ins Buendel'
$et = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\e2e_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Assert-That ($et -match 'Split-ChoicesMarker' -and $et -match 'answer_buttons = ') 'e2e_test trennt die Zeile ebenso'

if ($failed -eq 0) { Write-Host "choices_marker_test: alles gruen." -ForegroundColor Green } else { Write-Host "choices_marker_test: $failed Fehler." -ForegroundColor Red }
exit $failed
