#Requires -Version 5.1
# privacy_terms.ps1 -- macht aus einem (art, wert) der Instanz die Schreibweisen fuer die Denylist.
# Reine Funktion ohne Ein-/Ausgabe, damit der Test sie ohne Instanz pruefen kann. Dot-Sourcing wie scripts/lib/devenv.ps1.

# Eine Zahl (Punkt als Dezimaltrenner) in deutscher und englischer Schreibweise, ohne nachlaufende Nullen.
function Get-PrivacyAmountVariants([string]$Value) {
    $v = $Value.Trim().TrimStart('-')
    if ($v -notmatch '^[0-9]+(\.[0-9]+)?$') { return @() }
    if ($v.Contains('.')) { $v = $v.TrimEnd('0').TrimEnd('.') }
    $parts = $v -split '\.'
    $int = $parts[0]
    $frac = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $grouped = [regex]::Replace($int, '(?<=\d)(?=(\d{3})+$)', '.')
    $variants = @()
    if ($frac) {
        # Cent-Betraege auch zweistellig (der Wert 12.50 kommt hier als 12.5 an)
        $cents = if ($frac.Length -eq 1) { $frac + '0' } else { $frac }
        $variants += "$int.$cents", "$int,$cents", "$grouped,$cents"
    } else {
        $variants += $int, $grouped
    }
    @($variants | Sort-Object -Unique)
}

# Liefert alle Schreibweisen zu (art, wert); leer, wenn der Wert zu kurz oder nicht verwertbar ist.
function Get-PrivacyTermVariants([string]$Kind, [string]$Value) {
    $v = "$Value".Trim()
    if (-not $v) { return @() }
    switch ($Kind) {
        'amount' { return @(Get-PrivacyAmountVariants $v) }
        'date' {
            $out = @($v)
            if ($v -match '^(\d{4})-(\d{2})-(\d{2})') { $out = @("$($Matches[1])-$($Matches[2])-$($Matches[3])", "$($Matches[3]).$($Matches[2]).$($Matches[1])") }
            return $out
        }
        'id' {
            $compact = $v -replace '[\s./-]', ''
            if ($compact.Length -lt 5) { return @() }
            return @(@($v, $compact) | Sort-Object -Unique)
        }
        'name' { if ($v.Length -lt 3) { return @() }; return @($v) }
        'text' { if ($v.Length -lt 4) { return @() }; return @($v) }
        default { throw "Unbekannte Art: $Kind" }
    }
}
