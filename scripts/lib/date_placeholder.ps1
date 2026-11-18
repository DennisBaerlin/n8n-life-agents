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

# Bezugstag: der Tag, den enable_mock_llm.ps1 dem Mock gesetzt hat (State-Block mock_llm.today des aktuellen Substrats), damit
# Harness und Mock ueber 00:00 UTC hinweg denselben Wert rechnen. Ohne Mock-Block (kein Substrat, Selbsttests) das UTC-Datum
# beim Laden: ein Wert je Prozess. Get-DatePlaceholderReferenceDay ist die eine Adresse (Selbsttest: dev/date_placeholder_test.ps1).
function Get-DatePlaceholderReferenceDay {
    param([string]$StateFile)
    if (-not $StateFile) {
        # Ausserhalb eines Git-Checkouts (Mock-Kopie, CI-Container) gibt es keine Zustandsdatei -> UTC-Datum unten.
        try { . (Join-Path $PSScriptRoot 'n8ntest_state_file.ps1'); $StateFile = Get-TestN8nStateFile 2>$null } catch { $StateFile = $null }
    }
    if ($StateFile -and (Test-Path -LiteralPath $StateFile)) {
        try {
            $st = [System.IO.File]::ReadAllText($StateFile, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            $stamp = if ($st.PSObject.Properties['mock_llm'] -and $st.mock_llm.PSObject.Properties['today']) { [string]$st.mock_llm.today } else { '' }
            $day = [datetime]::MinValue
            if ($stamp -match '^\d{4}-\d{2}-\d{2}$' -and [datetime]::TryParseExact($stamp, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$day)) {
                # Der Mock rechnet mit demselben Tag, also folgt der Harness ihm; die DB (heute) kann bei altem Stempel abweichen -> Hinweis.
                if (([datetime]::UtcNow.Date - $day).TotalDays -gt 1) { Write-Warning "Datums-Bezugstag $stamp ist aelter als ein Tag (Mock seit damals ohne Neustart); enable_mock_llm.ps1 setzt ihn neu." }
                return $day
            }
        } catch { Write-Verbose "State ohne lesbaren Bezugstag: $($_.Exception.Message)" }
    }
    return [datetime]::UtcNow.Date
}
$script:DatePlaceholderToday = Get-DatePlaceholderReferenceDay

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

# Get-DatePlaceholderError <text> -> Liste von Fehlertexten (leer = in Ordnung): ein Platzhalter mit ungueltiger Grammatik oder ein
# Beinahe-Platzhalter ({{ date:..}}, {{Date:..}}, {date:..}, fehlendes Schliessen), der sonst still als Text durchginge. Fuer mock_lint (C4).
function Get-DatePlaceholderError {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $errs = @()
    if ([string]::IsNullOrEmpty($Text)) { return $errs }
    $strict = [regex]::Matches($Text, '\{\{date:[^}]*\}\}')
    foreach ($m in $strict) {
        try { [void](Get-DatePlaceholderValue -Expr $m.Value.Substring(7, $m.Value.Length - 9) -Today ([datetime]'2026-01-01')) }
        catch { $errs += $_.Exception.Message }
    }
    $loose = [regex]::Matches($Text, '(?i)\{\{\s*date|(?<!\{)\{date:').Count
    if ($loose -ne $strict.Count) { $errs += "Beinahe-Platzhalter: $($loose - $strict.Count) Vorkommen von {{date.. weichen von der Schreibweise {{date:<offset>[@<tag>]}} ab (Leerzeichen, Gross-/Kleinschreibung, einfache Klammer oder fehlendes }})." }
    return $errs
}

# Get-FixedDateFinding <Objekt> [-Today] -> Liste "<Pfad>: <Literal>" fuer jedes woertliche Kalenderdatum (ISO oder TT.MM.JJJJ) in
# den pruefrelevanten Feldern eines Falls (task, turns, expected_tool_args, expected_behavior) bzw. Szenarios (match, calls), das heute in der
# Zukunft liegt oder weniger als zwei Jahre zurueckliegt: so ein Datum kippt (Plan-Beginn vergangen, "letzte 12 Monate" verschiebt sich).
# Ein Objekt mit nichtleerem fixed_date_reason ist ausgenommen; notes/name/_comment/setup_sql werden nicht gelesen. Fuer mock_lint (C5).
$script:FixedDateKeys = @('task', 'turns', 'expected_tool_args', 'expected_behavior', 'match', 'calls')
function Get-FixedDateFinding {
    param($Obj, [datetime]$Today = $script:DatePlaceholderToday)
    if ($null -eq $Obj -or -not ($Obj -is [System.Management.Automation.PSCustomObject])) { return @() }
    if ($Obj.PSObject.Properties['fixed_date_reason'] -and -not [string]::IsNullOrWhiteSpace([string]$Obj.fixed_date_reason)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    $limit = $Today.AddYears(-2)
    $scan = {
        param($Node, $Path)
        if ($null -eq $Node) { return }
        if ($Node -is [string]) {
            $lits = @([regex]::Matches($Node, '\b(\d{4})-(\d{2})-(\d{2})\b') | ForEach-Object { , @($_.Value, $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value) }) +
                    @([regex]::Matches($Node, '\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b') | ForEach-Object { , @($_.Value, $_.Groups[3].Value, $_.Groups[2].Value, $_.Groups[1].Value) })
            foreach ($l in $lits) {
                $y = [int]$l[1]; $mo = [int]$l[2]; $dd = [int]$l[3]
                if ($y -lt 1 -or $mo -lt 1-or $mo -gt 12 -or $dd -lt 1 -or $dd -gt [datetime]::DaysInMonth($y, $mo)) { continue }
                if ((New-Object datetime ($y, $mo, $dd)) -gt $limit) { $out.Add("${Path}: $($l[0])") }
            }
        }
        elseif ($Node -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $Node.PSObject.Properties) { & $scan $p.Value "$Path.$($p.Name)" } }
        elseif ($Node -is [System.Collections.IEnumerable]) { $i = 0; foreach ($e in $Node) { & $scan $e "$Path[$i]"; $i++ } }
    }
    foreach ($k in $script:FixedDateKeys) { if ($Obj.PSObject.Properties[$k]) { & $scan $Obj.$k $k } }
    return $out.ToArray()
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
