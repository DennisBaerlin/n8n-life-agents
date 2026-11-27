#Requires -Version 5.1
# Laien-Messung ohne Modell: misst die Form dessen, was die Person liest, nicht die Verstaendlichkeit. Eingabe = Ausgaben einer
# Runde in der Form von ConvertTo-BotOutputs (lib/judge_card_text.ps1: method, text, buttons, card). Jeder Befund ist
# @{ rule; detail; excerpt }. Verbraucher: conversation_test (jede Runde), mock_lint (Antwort-Texte der Mock-Szenarien).
# Per Dot-Sourcing laden; Selbsttest scripts/dev/lay_metrics_test.ps1.
#   L1  hoechstens eine Frage je Nachricht (auch Karten).
#   L2  Gespraechstext hoechstens 600 Zeichen; nach einer Karte hoechstens ein Satz.
#   L3  eine Wahl steht als Knoepfe da, nie als nummerierte Wege mit Frage.
#   L9  nichts doppelt: keine Nachricht, keine Zeile an zwei Stellen, keine Liste und keine angenommene Karte zweimal.
#   L12 keine Merkarbeit (Muster-Liste je Sprache).
# Datenzeilen (Zeilenanfang "• ") zaehlen bei L2 nicht mit (wie im Karten-Test von locale_lint). Zitate in Anfuehrungszeichen
# (Beispiele, was man schreiben kann) und Links zaehlen bei L1, L3 und L12 nicht.

. (Join-Path $PSScriptRoot 'next_step_marker.ps1')
. (Join-Path $PSScriptRoot 'choices_marker.ps1')

$script:LayMaxChars    = 600
$script:LayMinSameText = 20    # kuerzere Wiederholungen ("Alles klar.") sind kein Fund
$script:LayMinSameLine = 40
$script:LayMinSameList = 80

# editMessageText aendert eine vorhandene Nachricht: ihr Text zaehlt fuer L1/L3/L12, aber weder als neuer Gespraechstext noch als Dopplung.
$script:LaySendMethods = @('sendMessage', 'sendDocument', 'sendPhoto', 'sendAnimation')
$script:LayTextMethods = $script:LaySendMethods + @('editMessageText')

# Muster je Sprache. Mit "ich"/"wir" bzw. "I"/"we" davor ist es eine Zusage des Bots ("ich merke dir den Termin vor",
# "I'll keep that in mind") und trifft nicht.
$script:LayBotDe = '(?<!\b(?:ich|wir)\s)'
$script:LayBotEn = '(?<!\b(?:I|we)(?:[''\u2019]ll|\s+will|\s+won[''\u2019]t|\s+can)?\s)'
$script:LayMemoryPatterns = @(
    "$($script:LayBotDe)\bmerke?\s+(?:(?:es|das|dir\s+das)\s+)?dir\b"
    '\bmerken\s+sie\s+sich\b'
    "$($script:LayBotDe)\bsag(?:e)?\s+mir\b[^.!?\n]{0,40}\bbescheid\b"
    "$($script:LayBotDe)\bsag\s+(?:(?:dann|einfach|bitte|gern|gerne|kurz)\s+)*bescheid\b"
    "$($script:LayBotDe)\bgib\s+(?:mir\s+)?(?:(?:dann|einfach|bitte|gern|gerne|kurz)\s+)*bescheid\b"
    "$($script:LayBotDe)\bdenke?\s+(?:(?:bitte|selbst|auch)\s+)*(?:daran|dran)\b"
    '\bdenken\s+sie\s+(?:(?:bitte|selbst|auch)\s+)*(?:daran|dran)\b'
    "$($script:LayBotDe)\bvergiss\s+(?:(?:das|es|bitte)\s+)?nicht\b"
    '\bvergessen\s+sie\s+(?:(?:das|es|bitte)\s+)?nicht\b'
    "$($script:LayBotDe)\berinnere?\s+mich\b"
    "$($script:LayBotDe)\bmelde?\s+dich\s+(?:dann\s+)?(?:noch\s?mal|wieder|bei\s+mir)\b"
    "$($script:LayBotDe)\b(?:behalte?|halte?)\b[^.!?\n]{0,30}\bim\s+(?:hinter)?kopf\b"
    "$($script:LayBotDe)\b(?:schreib|notier)e?\s+(?:(?:es|das)\s+)?dir\b"
    "$($script:LayBotEn)\b(?:remember|don[''\u2019]?t\s+forget|do\s+not\s+forget)\s+(?:to|that|this)\b"
    '\blet\s+me\s+know\s+(?:when|once|as\s+soon\s+as|after)\b'
    "$($script:LayBotEn)\bkeep\s+(?:(?:this|that|it)\s+)?in\s+mind\b"
    "$($script:LayBotEn)\bmake\s+a\s+note\b"
    "$($script:LayBotEn)\bremind\s+me\b"
    '기억해\s*(?:두|주)(?:세요|십시오)'
    '잊지\s*마'
    '메모해\s*(?:두|놓)(?:으)?(?:세요|십시오)'
)

function New-LayFinding([string]$Rule, [string]$Detail, [string]$Text) {
    $flat = [regex]::Replace("$Text", '\s+', ' ').Trim()
    if ($flat.Length -gt 80) { $flat = $flat.Substring(0, 77) + '...' }
    return [pscustomobject]@{ rule = $Rule; detail = $Detail; excerpt = $flat }
}

function Get-LayNormalized([string]$Text) { return [regex]::Replace("$Text", '\s+', ' ').Trim() }

# Text ohne Links und ohne Zitate: was darin steht, fragt oder verlangt der Bot nicht selbst.
function Get-LayOwnWords([string]$Text) {
    $t = [regex]::Replace("$Text", '(?i)\bhttps?://\S+', ' ')
    # „...“/” deutsch, “...” englisch, «/» Guillemets, gerade Anfuehrungszeichen
    $t = [regex]::Replace($t, '\u201E[^\u201C\u201D"\n]*[\u201C\u201D"]', ' ')
    $t = [regex]::Replace($t, '\u201C[^\u201D\n]*\u201D', ' ')
    $t = [regex]::Replace($t, '[\u00AB\u00BB][^\u00AB\u00BB\n]*[\u00AB\u00BB]', ' ')
    $t = [regex]::Replace($t, '"[^"\n]*"', ' ')
    return $t
}

function Get-LayQuestionCount([string]$Text) {
    return [regex]::Matches((Get-LayOwnWords $Text), '[?\uFF1F]+').Count
}

# Ohne Datenzeilen; das ist der Teil, den die Person als Gespraech liest.
function Get-LayProse([string]$Text) {
    return ((@("$Text" -split "`r?`n") | Where-Object { -not $_.TrimStart().StartsWith([string][char]0x2022) }) -join "`n").Trim()
}

$script:LayMonthWords = '(?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|des|jedes)\b'

# Ein Block aus Aufzaehlung oder Statuszeilen (Punkt, Strich, Nummer, Zeichen wie Haken/Kaestchen/Emoji) ist eine Uebersicht, kein
# Gespraech: ab zwei Zeilen. Mit Knopf reicht ein Punkt mit Nummer oder Aufzaehlungspunkt unter einer Einleitung (Systemliste mit
# einem Eintrag, z. B. fuer die Bank); Haken, Zeigefinger, Strich oder eine erste Zeile machen daraus keine Liste. "1. Maerz ..." ist ein Datum.
function Test-LayList([string]$Text, [int]$Buttons = 0) {
    $marker = "(?m)^\s*(?:[\u2022\u2013-]|\p{So}|[\uD800-\uDBFF][\uDC00-\uDFFF]|\d{1,2}[.)](?!\s*$($script:LayMonthWords)))\s+\S"
    if ([regex]::Matches("$Text", $marker).Count -ge 2) { return $true }
    if ($Buttons -le 0) { return $false }
    $item = "^\s*(?:•|\d{1,2}[.)](?!\s*$($script:LayMonthWords)))\s+\S"
    $lines = @("$Text" -split "`n" | Where-Object { $_.Trim() })
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $item) { return $true } }
    return $false
}

function Get-LaySentenceCount([string]$Text) {
    # Abkuerzungen, Zahl- und Datumspunkte sind kein Satzende
    $m = [regex]::Replace("$Text", '\b(?:z\.\s?B|z\.\s?T|d\.\s?h|u\.\s?a|e\.\s?g|i\.\s?e|p\.\s?a|p\.\s?M)\.', 'X')
    $m = [regex]::Replace($m, '\b(?:bzw|ca|Nr|ggf|inkl|exkl|evtl|bspw|etc|usw|mtl|monatl|jährl|vgl|Dr|Mio|Mrd|Std)\.', 'X')
    $m = [regex]::Replace($m, '(?<=\d)\.(?=\s?[\d\p{Ll})])', '')
    $m = [regex]::Replace($m, "\b(\d{1,2})\.(?=\s+$($script:LayMonthWords))", '$1')
    return @([regex]::Split($m, '(?<=[.!?\u3002\uFF1F])\s+|\r?\n+') | Where-Object { $_ -match '\p{L}' }).Count
}

# Nummerierte oder benannte Wege plus Aufforderung, sich zu entscheiden. Eine Rueckfrage nach einer Anleitung ("Klappt das?") ist
# keine Wahl: die Frage muss eine Auswahl verlangen, oder der Text nennt selbst "Wege"/"Varianten".
function Test-LayWrittenChoice([string]$Text) {
    $own = Get-LayOwnWords $Text
    $numbered = [regex]::IsMatch($own, '(?m)^\s*(?:1[.)]|1️⃣|[aA]\))\s+\S') -and [regex]::IsMatch($own, '(?m)^\s*(?:2[.)]|2️⃣|[bB]\))\s+\S')
    $inline = [regex]::IsMatch($own, '(?s)\b(?:Weg|Variante|Option|Möglichkeit)\s+(?:1|A)\b.*\b(?:Weg|Variante|Option|Möglichkeit)\s+(?:2|B)\b') -or
              [regex]::IsMatch($own, '(?s)\(1\)\s*\S.*\(2\)\s*\S')
    if (-not ($numbered -or $inline)) { return $false }
    if ([regex]::IsMatch($own, '(?i)\b(?:antworte|schreib|tippe?|reply|answer|choose|pick)\b[^.\n]{0,30}\b[12AB]\b')) { return $true }
    $questions = @([regex]::Split($own, '(?<=[.!?\uFF1F])\s+|\r?\n+') | Where-Object { $_ -match '[?\uFF1F]' })
    if (-not $questions.Count) { return $false }
    if ($own -match '(?i)\b(?:Wege|Varianten|Optionen|Möglichkeiten|options|ways)\b') { return $true }
    return [bool](@($questions -match '(?i)\b(?:welche[rsmn]?|was davon|lieber|oder|wähl\w*|entscheid\w*|möchtest|willst|soll ich|passt dir|which|rather|or|prefer)\b').Count)
}

function Get-LayMemoryHit([string]$Text) {
    $own = Get-LayOwnWords $Text
    foreach ($p in $script:LayMemoryPatterns) {
        $m = [regex]::Match($own, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return $m.Value }
    }
    return $null
}

# Regeln, die an einer einzelnen Nachricht haengen. -Conversation: neuer Text, keine Karte (L2-Laenge).
function Get-LayMessageFindings([string]$Text, [int]$Buttons, [switch]$Conversation) {
    $q = Get-LayQuestionCount $Text
    if ($q -gt 1) { New-LayFinding 'L1' "$q Fragen in einer Nachricht (hoechstens eine)" $Text }
    if ($Conversation) {
        $len = (Get-LayProse $Text).Length
        if ($len -gt $script:LayMaxChars) { New-LayFinding 'L2' "$len Zeichen Gespraechstext (hoechstens $($script:LayMaxChars))" $Text }
    }
    if ($Buttons -eq 0 -and (Test-LayWrittenChoice $Text)) { New-LayFinding 'L3' 'Wahl als nummerierte Wege im Text statt als Knoepfe' $Text }
    $hit = Get-LayMemoryHit $Text
    if ($hit) { New-LayFinding 'L12' "Merkarbeit fuer die Person: '$hit'" $Text }
}

# Zeilen, die als Hinweis an zwei Stellen zaehlen (Datenzeilen duerfen sich wiederholen: gleiche Betraege, gleiche Namen).
function Get-LayHintLines([string]$Text) {
    return @("$(Get-LayProse $Text)" -split "`n" | ForEach-Object { Get-LayNormalized $_ } | Where-Object { $_.Length -ge $script:LayMinSameLine } | Select-Object -Unique)
}

# Dopplungen innerhalb einer Runde.
function Get-LayRoundDuplicates($Sent) {
    $texts = @($Sent | ForEach-Object { Get-LayNormalized $_.text })
    for ($i = 0; $i -lt $Sent.Count; $i++) {
        for ($j = $i + 1; $j -lt $Sent.Count; $j++) {
            if ($texts[$i] -ceq $texts[$j]) {
                if ($texts[$i].Length -ge $script:LayMinSameText) { New-LayFinding 'L9' 'dieselbe Nachricht zweimal in einer Runde' $Sent[$j].text }
                continue
            }
            # Zwei Karten duerfen dieselbe Kurzzeile tragen (je Karte gewollt); Karte plus Text ist derselbe Hinweis an zwei Stellen.
            if ($Sent[$i].card -and $Sent[$j].card) { continue }
            $other = Get-LayHintLines $Sent[$j].text
            foreach ($line in (Get-LayHintLines $Sent[$i].text)) {
                if ($other -ccontains $line) { New-LayFinding 'L9' 'derselbe Satz an zwei Stellen' $line; break }
            }
        }
    }
}

# Dopplungen gegen fruehere Runden desselben Falls. Dieselbe Eingabe darf dieselbe Antwort bekommen.
function Get-LayHistoryDuplicates($Sent, [string]$UserInput, $History) {
    foreach ($o in $Sent) {
        $norm = Get-LayNormalized $o.text
        $isList = @("$($o.text)" -split "`n" | Where-Object { $_.Trim() }).Count -ge 2 -and $norm.Length -ge $script:LayMinSameList
        if (-not $o.card -and -not $isList) { continue }
        foreach ($r in @($History)) {
            if (-not $r -or "$($r.input)" -ceq $UserInput) { continue }
            if ($o.card -and "$($r.card_decision)" -ne 'angenommen') { continue }
            $same = @(@($r.outputs) | Where-Object { $_ -and $script:LaySendMethods -contains "$($_.method)" -and [bool]$_.card -eq [bool]$o.card -and (Get-LayNormalized $_.text) -ceq $norm })
            if ($same.Count -eq 0) { continue }
            if ($o.card) { New-LayFinding 'L9' 'dieselbe Karte kommt nach ihrer Bestaetigung wieder' $o.text }
            else { New-LayFinding 'L9' 'dieselbe Liste zum zweiten Mal' $o.text }
            break
        }
    }
}

# Eine Runde messen. $History = fruehere Runden desselben Falls als @{ input; outputs; card_decision }.
function Measure-BotOutput {
    param($Outputs, [string]$UserInput, $History)
    $all  = @(@($Outputs) | Where-Object { $_ })
    $sent = @($all | Where-Object { $script:LaySendMethods -contains "$($_.method)" -and "$($_.text)".Trim() })
    $cardSeen = $false
    foreach ($o in $all) {
        $method = "$($o.method)"; $text = "$($o.text)"
        if (-not $text.Trim()) { continue }
        if ($method -eq 'answerCallbackQuery') {
            $hit = Get-LayMemoryHit $text
            if ($hit) { New-LayFinding 'L12' "Merkarbeit fuer die Person: '$hit'" $text }
            continue
        }
        if ($script:LayTextMethods -notcontains $method) { continue }
        $isNew = $script:LaySendMethods -contains $method
        Get-LayMessageFindings -Text $text -Buttons @($o.buttons | Where-Object { $_ }).Count -Conversation:($isNew -and -not $o.card)
        if ($o.card) { $cardSeen = $true; continue }
        if ($cardSeen -and $isNew -and -not (Test-LayList $text @($o.buttons | Where-Object { $_ }).Count)) {
            $n = Get-LaySentenceCount $text
            if ($n -gt 1) { New-LayFinding 'L2' "$n Saetze nach einer Karte (hoechstens einer)" $text }
        }
    }
    Get-LayRoundDuplicates $sent
    Get-LayHistoryDuplicates $sent $UserInput $History
}

function Test-LayDataText([string]$Text) {
    $t = "$Text".Trim()
    if (-not ($t.StartsWith('{') -or $t.StartsWith('['))) { return $false }
    try { $null = ConvertFrom-Json -InputObject $t -ErrorAction Stop; return $true } catch { return $false }
}

# Ein einzelner Antworttext eines Modells (Mock-Szenario): Markerzeilen nimmt das System vor dem Senden heraus. Reine JSON-Antworten
# liest ein Knoten, nie die Person.
function Measure-BotText {
    param([string]$Text)
    if (Test-LayDataText $Text) { return }
    $step = Split-NextStepMarker $Text
    $choices = Split-ChoicesMarker $step.text
    $body = "$($choices.text)"
    if (-not $body.Trim()) { return }
    Get-LayMessageFindings -Text $body -Buttons @($choices.options).Count -Conversation
    $seen = @{}
    foreach ($line in @((Get-LayProse $body) -split "`n" | ForEach-Object { Get-LayNormalized $_ } | Where-Object { $_.Length -ge $script:LayMinSameLine })) {
        if ($seen.ContainsKey($line)) { New-LayFinding 'L9' 'derselbe Satz zweimal' $line; break }
        $seen[$line] = $true
    }
}
