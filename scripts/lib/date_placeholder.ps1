#Requires -Version 5.1
# Datums-Platzhalter der Testfaelle: {{date:<offset>[@<tag>]}}, aufgeloest vor dem Senden bzw. Vergleichen. Dot-sourcen:
#   . "$PSScriptRoot\lib\date_placeholder.ps1"     (aus scripts/dev: "..\lib")
# Grammatik (eine Syntax fuer task-Text, expected_tool_args, expected_behavior und Mock-Szenarien; JS-Zwilling in
# tests/mock_llm/server.js, beide gegen tests/util/date_placeholder_vectors.json geprueft, Selbsttest dev/date_placeholder_test.ps1):
#   <offset>  = [+-]N d|w|m   Tage, Wochen, Monate ab heute (0d = heute); Monatsende klemmt wie AddMonths (31.1. +1m = 28.2.)
#   @<tag>    = danach auf den naechsten Tag des Monats mit dieser Nummer (1-31), derselbe Tag zaehlt; Monate ohne diese
#               Nummer werden uebersprungen. Anlass: fn_resolve_plan_schedule nimmt nur Ausfuehrungstage der Bank (z. B. 2./9./16./23.).
#   @-N       = vom Monatsende gezaehlt: @-1 letzter, @-2 vorletzter Tag des Monats (Monatslaenge und Schaltjahr beachtet).
#   {{date:+30d@2}} = heute + 30 Tage, dann der naechste 2. des Monats. Ergebnis immer YYYY-MM-DD.
# "Heute" ist das UTC-Datum: der Mock-Stub im Container rechnet in UTC, beide Seiten muessen dasselbe Datum bekommen.
# Ein Platzhalter, der die Grammatik verfehlt, wirft (Tippfehler duerfen nicht als Text durchgehen).

# Ein Bezugstag je Prozess (beim Laden fixiert): alle Faelle eines Laufs bekommen denselben Wert, auch ueber Mitternacht hinweg.
$script:DatePlaceholderToday = [datetime]::UtcNow.Date

function Get-DatePlaceholderValue {
    param([Parameter(Mandatory)][string]$Expr, [Parameter(Mandatory)][datetime]$Today)
    $m = [regex]::Match($Expr, '^([+-]?)(\d+)([dwm])(?:@(-?\d{1,2}))?$')
    if (-not $m.Success) { throw "Ungueltiger Datums-Platzhalter '{{date:$Expr}}' (erwartet {{date:+30d@2}}: [+-]N d|w|m, optional @Tag 1-31 oder @-1..-31 vom Monatsende)." }
    $n = [int]$m.Groups[2].Value; if ($m.Groups[1].Value -eq '-') { $n = -$n }
    $d = switch ($m.Groups[3].Value) { 'd' { $Today.AddDays($n) } 'w' { $Today.AddDays(7 * $n) } 'm' { $Today.AddMonths($n) } }
    if ($m.Groups[4].Success) {
        $day = [int]$m.Groups[4].Value
        if ($day -eq 0 -or [Math]::Abs($day) -gt 31) { throw "Ungueltiger Datums-Platzhalter '{{date:$Expr}}': Tag $day ausserhalb 1-31 bzw. -1..-31." }
        $first = New-Object datetime ($d.Year, $d.Month, 1)
        for ($k = 0; $k -le 12; $k++) {
            $month = $first.AddMonths($k)
            $dim = [datetime]::DaysInMonth($month.Year, $month.Month)
            $want = if ($day -gt 0) { $day } else { $dim + $day + 1 }   # @-1 = letzter, @-2 = vorletzter Tag
            if ($want -lt 1 -or $want -gt $dim) { continue }
            $cand = New-Object datetime ($month.Year, $month.Month, $want)
            if ($cand -ge $d.Date) { $d = $cand; break }
        }
    }
    return $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

# Resolve-DatePlaceholder <text> [-Today] -> Text mit aufgeloesten Platzhaltern (ohne Platzhalter unveraendert).
function Resolve-DatePlaceholder {
    param([AllowNull()][AllowEmptyString()][string]$Text, [datetime]$Today = $script:DatePlaceholderToday)
    if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf('{{date:', [StringComparison]::Ordinal) -lt 0) { return $Text }
    $eval = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) Get-DatePlaceholderValue -Expr $m.Groups[1].Value -Today $Today }
    return [regex]::Replace($Text, '\{\{date:([^}]*)\}\}', $eval)
}

# Resolve-DatePlaceholderDeep <Objekt> -> dasselbe Objekt, alle Strings darin aufgeloest (PSCustomObject aus ConvertFrom-Json wird
# in place geaendert, Arrays neu gebaut). Fuer ganze Testfaelle: $cases = @($cases | ForEach-Object { Resolve-DatePlaceholderDeep $_ })
function Resolve-DatePlaceholderDeep {
    param($Obj, [datetime]$Today = $script:DatePlaceholderToday)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [string]) { return (Resolve-DatePlaceholder -Text $Obj -Today $Today) }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($Obj.PSObject.Properties)) { $p.Value = Resolve-DatePlaceholderDeep -Obj $p.Value -Today $Today }
        return $Obj
    }
    # Unaeres Komma: sonst entpackt PowerShell ein Ein-Element-Array beim Rueckgeben zum Einzelwert.
    if ($Obj -is [System.Collections.IEnumerable]) { return , @(foreach ($e in $Obj) { Resolve-DatePlaceholderDeep -Obj $e -Today $Today }) }
    return $Obj
}
