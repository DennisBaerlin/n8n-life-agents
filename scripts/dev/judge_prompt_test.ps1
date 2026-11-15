#Requires -Version 5.1
# Selbsttest der Judge-Prompt-Bausteine (scripts/lib/judge_prompt.ps1): der Karten-Entscheid eines Eintrags steuert die
# Karten-Regel im System-Text und steht im User-Text; ohne Feld bleibt es bei "abgelehnt" (n8n_test, orch_test, alte
# Bundles). Dazu: der Weg Durchspiel -> Bundle-Datei -> Judge behaelt das Feld. Kein Substrat, kein API-Aufruf, keine Kosten.
# Usage:  .\scripts\dev\judge_prompt_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\judge_prompt.ps1')
. (Join-Path $repo 'scripts\dev\test_n8n_state.ps1')

$fail = 0
function Check([bool]$Ok, [string]$Msg) {
    if ($Ok) { Write-Host "[PASS] $Msg" -ForegroundColor Green }
    else { Write-Host "[FAIL] $Msg" -ForegroundColor Red; $script:fail++ }
}

$declined = Get-JudgeSystemText 'declined'
$approved = Get-JudgeSystemText 'approved'
Check ($declined -cmatch 'ABGELEHNT' -and $declined -cnotmatch 'ANGENOMMEN') 'System-Text declined: Karte abgelehnt, nichts von angenommen'
Check ($approved -cmatch 'ANGENOMMEN' -and $approved -cnotmatch 'ABGELEHNT') 'System-Text approved: Karte angenommen, nichts von abgelehnt'
Check ((Get-JudgeSystemText) -eq $declined) 'System-Text ohne Argument = declined'
# Der Rest der Regeln ist in beiden Fassungen gleich (nur die Karten-Regel wechselt).
Check ($declined -match 'READ_TOOLS ist unvollstaendig' -and $approved -match 'READ_TOOLS ist unvollstaendig' -and $approved -match 'Antworte AUSSCHLIESSLICH') 'Restregeln und Antwortformat in beiden Fassungen'
# Kann-Punkte (darf/may) sind kein Abzug; der Judge bewertet alle Agenten, nicht nur finance.
Check ($declined -match 'Kann-Punkte der Rubric' -and $approved -match 'Kann-Punkte der Rubric' -and $declined -match "'darf', 'may'") 'Kann-Punkte-Regel in beiden Fassungen'
Check ($declined -match 'eines Agenten' -and $declined -notmatch 'Finanz-Agent') 'Judge-Kopf nennt keinen Paket-Agenten'

$base = [pscustomobject]@{ task = 'Buche 5 EUR'; expected_behavior = 'bucht'; actual_output = 'Gebucht.' }
$withApproved = [pscustomobject]@{ task = 'Buche 5 EUR'; expected_behavior = 'bucht'; actual_output = 'Gebucht.'; card_decision = 'approved' }
$withDeclined = [pscustomobject]@{ task = 'x'; card_decision = 'declined' }
$weird = [pscustomobject]@{ task = 'x'; card_decision = 'whatever' }
Check ((Get-JudgeCardDecision $base) -eq 'declined') 'Eintrag ohne Feld = declined (Rueckwaerts-Kompatibilitaet)'
Check ((Get-JudgeCardDecision $withApproved) -eq 'approved') 'Eintrag mit approved = approved'
Check ((Get-JudgeCardDecision $withDeclined) -eq 'declined') 'Eintrag mit declined = declined'
Check ((Get-JudgeCardDecision $weird) -eq 'declined') 'unbekannter Wert = declined'
Check ((Format-JudgeUserText $base) -match 'CARD_DECISION: declined') 'User-Text ohne Feld nennt declined'
Check ((Format-JudgeUserText $withApproved) -match 'CARD_DECISION: approved') 'User-Text mit approved nennt approved'

# Bundle-Datei: ein Durchspiel-Eintrag mit approved bleibt ueber Schreiben und Lesen erhalten.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("judge_prompt_test_" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $tmp 'tests\agent') -Force | Out-Null
    $entry = [ordered]@{ id = 's6-r08'; name = 'x'; task = 'Buche'; expected_behavior = 'bucht'; card_decision = 'approved'; actual_output = 'Gebucht.' }
    Write-JudgeBundle -Entries @($entry) -RepoRoot $tmp | Out-Null
    $bundle = [System.IO.File]::ReadAllText((Join-Path $tmp 'tests\agent\judge_bundle.json'), (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    Check ((Get-JudgeCardDecision @($bundle)[0]) -eq 'approved') 'Bundle-Datei: card_decision approved ueberlebt Schreiben und Lesen'
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

# Verdrahtung: das Durchspiel schreibt den Entscheid, judge_eval nutzt die Bausteine (kein Text-Duplikat mehr).
$conv = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\conversation_test.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Check ($conv.Contains("card_decision = `$(if (`$rd.card_decision -eq 'angenommen') { 'approved' } else { 'declined' })")) 'conversation_test schreibt card_decision je Bundle-Eintrag'
$je = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\judge_eval.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Check ($je -match 'lib\\judge_prompt\.ps1' -and $je -match 'Get-JudgeSystemText \(Get-JudgeCardDecision \$Entry\)' -and $je -notmatch '\$SystemText = ') 'judge_eval nutzt Get-JudgeSystemText je Eintrag'

if ($fail -eq 0) { Write-Host 'judge_prompt_test: alle Pruefungen bestanden.' -ForegroundColor Green }
else { Write-Host "judge_prompt_test: $fail Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $fail
