#Requires -Version 5.1
# Die Markerzeile NEXT_STEP der Router-/Hilfe-Agent-Grammatik (core.fn_get_next_step): der Agent schreibt sie als letzte Zeile, das System
# nimmt sie vor dem Senden aus dem Text und haengt den Knopf an. Eine Quelle fuer die Erkennung: der Relay-Baustein
# (scripts/build/lib/build_helpers.ps1, New-TelegramRelayChain) setzt dieses Muster in sein JavaScript ein, der Direkt-Test
# (n8n_test) trennt die Zeile damit vom Agententext. Per Dot-Sourcing laden; Selbsttest dev/next_step_marker_test.ps1.
# Das Muster gilt je Zeile und ist in .NET und JavaScript gleich lesbar.
$script:NextStepMarkerPattern = '^\s*NEXT_STEP\s*$'

# Beschriftung des vom System gewaehlten naechsten Schritts (core.fn_get_next_step, Knoten-Ausgabe step.label) aus dem runData eines
# Agenten; '' wenn kein Knoten sie traegt. Der Knopf unter der Antwort zeigt genau diesen Schritt.
function Get-SystemNextStepLabel([object]$RunData) {
    foreach ($p in $RunData.PSObject.Properties) {
        foreach ($r in @($p.Value)) {
            $lbl = $null; try { $lbl = $r.data.main[0][0].json.step.label } catch { }
            if ($lbl) { return "$lbl" }
        }
    }
    return ''
}

# Entfernt jede Markerzeile aus dem Text (wie der Relay) und meldet, ob eine da war. Rueckgabe: @{ text; marker }.
function Split-NextStepMarker([string]$Text) {
    $kept = @(); $found = $false
    foreach ($l in ("$Text" -split "`n")) {
        if ($l -match $script:NextStepMarkerPattern) { $found = $true } else { $kept += $l }
    }
    return @{ text = (($kept -join "`n").Trim()); marker = $found }
}
