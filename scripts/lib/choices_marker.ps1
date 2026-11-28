#Requires -Version 5.1
# Die Markerzeile CHOICES der Berater-Grammatik (packages/core/contexts/advisor_conversation.md): der Berater schreibt als letzte Zeile
# "CHOICES a | b | c", das System nimmt sie aus dem Text und macht aus den Optionen Knoepfe (offene Frage, Art choice). Eine Quelle fuer
# die Erkennung: der Relay im Orchestrator setzt diese Regeln in sein JavaScript ein, der Direkt-Test (n8n_test) trennt die Zeile damit
# vom Agententext und gibt dem Bewerter die Knoepfe mit, ebenso e2e_test; lay_metrics (Measure-BotText) nimmt sie vor der Messung
# heraus. Per Dot-Sourcing laden; Selbsttest dev/choices_marker_test.ps1.
# Auch Abwandlungen des Modells (CHOICES:, **CHOICES**, Choices mit |) gelten als Markerzeile, damit nie eine roh beim Nutzer landet;
# klein geschrieben nur mit Trennstrich, sonst waere ein Satz, der mit dem Wort beginnt, weg.
# Gueltig nur als letzte nicht-leere Zeile mit 2-3 Optionen zu je 1-24 Zeichen ohne Link; eine ungueltige oder nicht-letzte
# Markerzeile wird trotzdem entfernt (nie roh senden), ergibt aber keine Knoepfe.
$script:ChoicesMarkerPattern = '^\s*[*_]*\s*(?:CHOICES|(?:Choices|choices)(?=[^|]*\|))[*_]*\s*:?\s+(.*?)\s*$'
$script:ChoicesMaxOptions = 3
$script:ChoicesMinOptions = 2
$script:ChoicesMaxLength = 24

# Rueckgabe: @{ text; options } - options leer, wenn keine gueltige Markerzeile am Ende stand.
function Split-ChoicesMarker([string]$Text) {
    $lines = @("$Text" -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $lastIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i].Trim()) { $lastIdx = $i; break } }
    $kept = @(); $options = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], $script:ChoicesMarkerPattern)
        if (-not $m.Success) { $kept += $lines[$i]; continue }
        if ($i -ne $lastIdx) { continue }
        $opts = @($m.Groups[1].Value -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $bad = @($opts | Where-Object { $_.Length -gt $script:ChoicesMaxLength -or $_ -match '(?i)https?:|://|t\.me/' })
        if ($opts.Count -ge $script:ChoicesMinOptions -and $opts.Count -le $script:ChoicesMaxOptions -and $bad.Count -eq 0) { $options = $opts }
    }
    return @{ text = (($kept -join "`n").Trim()); options = $options }
}
