#Requires -Version 5.1
# ordinal.ps1 -- Sortieren ohne Kultur. Dot-Sourcing: . (Join-Path $PSScriptRoot 'lib\ordinal.ps1')
# Sort-Object vergleicht in der Kultur des Rechners: eine erzeugte Datei (Faehigkeiten-Katalog, docs/fn_catalog.md) haette je Rechner
# und in der CI eine andere Reihenfolge, und ihr Vergleich mit dem getrackten Stand schluege fehl.
# Sort-Ordinal <string[]> -> string[] in der Reihenfolge der Zeichen-Codes ($null oder leer -> leeres Array).
function Sort-Ordinal([string[]]$Items) {
    if ($null -eq $Items -or $Items.Count -eq 0) { return @() }
    $a = [string[]]$Items
    [Array]::Sort($a, [System.StringComparer]::Ordinal)
    return $a
}
