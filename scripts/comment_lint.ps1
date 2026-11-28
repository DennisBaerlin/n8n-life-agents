#Requires -Version 5.1
# comment_lint.ps1 -- Waechter fuer .claude/rules/comments.md (hartes Gate, nur neue und geaenderte Zeilen).
# Der Bestand wird nicht angefasst: geprueft werden nur Kommentarzeilen, die der Diff hinzufuegt. Was als Kommentar zaehlt,
# entscheidet je Sprache ein Scanner (PowerShell = echter Tokenizer; SQL, bash, JS = Zustandsautomat mit String-, Here-Doc-,
# Dollar-Quote- und Template-Zustand), damit Text in Here-Strings und String-Literalen nie trifft.
# Regeln (Kennung in eckigen Klammern; Pruefnummern in Lints sind Adressen und treffen nicht):
#   [verlauf]  Herkunft und Verlauf: Befund/Fund + Datum, "neu seit/ab",  comment-lint: ok Regeltext
#              "seit/bis vX.Y", "(vX.Y.Z)", "KW45 Fund/Sprint", "(KW45)", "Phase B",  comment-lint: ok Regeltext
#              das Wort fuer "einst" (auch vormals/ehemals) als Rueckblick.
#              Dazu Arbeits-Marken (wer, wann, welches Arbeitspaket): Owner/Abnahme/Entscheid/Lauf + Datum, "Owner-Runde",  comment-lint: ok Regeltext
#              "Probelauf-Fund", "(Paket 3)", "Paket 2/5", "Einwand 4", "Pruefliste Nr. 7", "Bug B4", "(P5)" ohne Test-Verweis,  comment-lint: ok Regeltext
#              und Verweise auf Plaene: "Plan <name-mit-bindestrich>", "Plan *Titel*", .claude/plans/, .local/handover/.  comment-lint: ok Regeltext
#   [code]     auskommentierter Code: Zuweisung, Kontrollkopf mit Klammer, einzelne Klammer, SQL-Anweisung mit Semikolon.
#              Der Kopf-Block einer Datei ist ausgenommen (Aufruf-Beispiele gehoeren hinein).
#   [todo]     TODO/FIXME ohne Ausloeser: erlaubt sind "TODO(<Ausloeser>)" oder "TODO wenn/sobald/nach/falls/bei ...".  comment-lint: ok Regeltext
#   [caps]     Betonung in Grossbuchstaben (feste Wortliste; Abkuerzungen wie JSON, NULL, HITL treffen nicht).
#   [kopf]     Pflichtteile tragender Koepfe neuer Dateien: scripts/**/*.ps1 (ohne lib/) mit Aufruf-Beispiel und Exit-Code;
#              R__fn_*.sql mit Titelzeile "-- fn_<name>" und mindestens einer Beschreibungszeile; packages/*/build/**/*.ps1 mit
#              mindestens zwei Kopfzeilen; provisioning/lib/*.sh mit erster Zeile "<datei> — <Zweck>" und wer sie sourct;
#              provisioning/*.sh mit Aufruf und Exit-Code. "Dot-gesourct von <datei>.ps1" im Kopf verlangt, dass es die Datei gibt.
# Ausnahme je Zeile: "comment-lint: ok <Grund>" im selben Kommentar (Lint-Marker, bleibt stehen).
# Nicht geprueft (bewusst): generierte Dateien (packages/*/workflows/, docs/site/public/), node_modules/, jsCode in Build-Defs
# (liegt in PowerShell-Here-Strings).
# Aufruf:
#   .\scripts\comment_lint.ps1                     # Arbeitsbaum gegen merge-base mit origin/main (Fallback main)
#   .\scripts\comment_lint.ps1 -Staged             # nur der gestagte Diff (prek-Hook)
#   .\scripts\comment_lint.ps1 -Base <rev>         # Arbeitsbaum gegen <rev> (CI: PR-Basis bzw. Vor-Push-Stand)
#   .\scripts\comment_lint.ps1 -All [-Verbose]     # ganzer Baum, nur Bericht der Treffer je Regel, Exit 0
#   .\scripts\comment_lint.ps1 -Files a.ps1,b.sql -Json   # alle Kommentarzeilen der Dateien pruefen, Funde (File, Line, Rule) als JSON (Test)
# Exit-Code = Anzahl Funde (bei -All und -Json 0); vorab laufen Selbst-Asserts der Scanner, schlagen sie fehl, deren Anzahl.
# Kein LLM, kein Netz, kein Substrat. Test: scripts/dev/comment_lint_test.ps1.
param([string]$Base, [switch]$Staged, [switch]$All, [string[]]$Files, [switch]$Json, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel)
$u8 = New-Object System.Text.UTF8Encoding($false)
# Ueber powershell.exe -File kommt eine Liste als EIN String an ("a,b").
$Files = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# --- Dateiauswahl ----------------------------------------------------------------------------------------------
$excludeRx = '^(packages/[^/]+/workflows/|docs/site/public/)|(^|/)node_modules/'
function Get-Lang([string]$Path) {
    if ($Path -match '\.ps1$') { return 'ps' }
    if ($Path -match '\.sql$') { return 'sql' }
    if ($Path -match '\.sh$' -or $Path -eq 'provisioning/templates/lifeagents.tpl') { return 'sh' }
    if ($Path -match '\.js$') { return 'js' }
    return $null
}

# --- Kommentar-Extraktion je Sprache: Liste von @{ Line; Text; Head } ------------------------------------------
# Head = Zeile gehoert zum fuehrenden Kommentar-Block der Datei (vor dem ersten Code).
function New-C([int]$Line, [string]$Text, [bool]$Head) { [pscustomobject]@{ Line = $Line; Text = $Text; Head = $Head } }

function Get-PsComments([string]$Src) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Src, [ref]$tokens, [ref]$errs)
    $head = $true
    foreach ($t in $tokens) {
        $k = [string]$t.Kind
        if ($k -eq 'NewLine' -or $k -eq 'EndOfInput' -or $k -eq 'LineContinuation') { continue }
        if ($k -ne 'Comment') { $head = $false; continue }
        $n = $t.Extent.StartLineNumber
        foreach ($l in ($t.Text -split "`r?`n")) {
            $body = $l -replace '^\s*<#', '' -replace '#>\s*$', '' -replace '^\s*#', ''
            New-C $n $body $head
            $n++
        }
    }
}

# Zeilennummer eines Offsets: Binaersuche ueber die Zeilenanfaenge.
function Get-LineStarts([string]$Src) {
    $s = New-Object System.Collections.Generic.List[int]; $s.Add(0)
    $i = $Src.IndexOf("`n")
    while ($i -ge 0) { $s.Add($i + 1); $i = $Src.IndexOf("`n", $i + 1) }
    , $s.ToArray()
}
function Get-LineOf([int[]]$Starts, [int]$Off) {
    $k = [Array]::BinarySearch($Starts, $Off)
    if ($k -ge 0) { return $k + 1 }
    return (-bnot $k)
}
# Kommentar-Token in Zeilen zerlegen (Block-Kommentare spannen mehrere Zeilen).
function Add-CommentToken($Out, [int[]]$Starts, [int]$Off, [string]$Body, [bool]$Head) {
    $n = Get-LineOf $Starts $Off
    foreach ($l in ($Body -split "`r?`n")) { $Out.Add((New-C $n ($l.TrimEnd("`r")) $Head)); $n++ }
}

# SQL: ein Dollar-Quote direkt nach AS oder DO ist ein Funktionsrumpf (Kommentare darin zaehlen); jeder andere, auch auf oberster
# Ebene (COMMENT ON ... IS $c$...$c$), ist ein String.
$sqlTokRx = [regex]'--[^\n]*|/\*[\s\S]*?\*/|(?<![A-Za-z0-9_])[Ee]''(?:[^''\\]|\\[\s\S]|'''')*''|''(?:[^'']|'''')*''|"[^"]*"|\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$'
function Get-SqlComments([string]$Src) {
    $out = New-Object System.Collections.Generic.List[object]
    $starts = Get-LineStarts $Src
    $pos = 0; $head = $true; $bodyTag = $null
    while ($pos -lt $Src.Length) {
        $m = $sqlTokRx.Match($Src, $pos)
        if (-not $m.Success) { break }
        if ($head -and $m.Index -gt $pos -and -not [string]::IsNullOrWhiteSpace($Src.Substring($pos, $m.Index - $pos))) { $head = $false }
        $v = $m.Value
        if ($v.StartsWith('--')) { Add-CommentToken $out $starts $m.Index $v.Substring(2) $head; $pos = $m.Index + $m.Length; continue }
        if ($v.StartsWith('/*')) { Add-CommentToken $out $starts $m.Index $v.Substring(2, $v.Length - 4) $head; $pos = $m.Index + $m.Length; continue }
        $head = $false
        if ($v.StartsWith('$')) {
            $before = $Src.Substring([Math]::Max(0, $m.Index - 12), [Math]::Min(12, $m.Index))
            if ($null -eq $bodyTag -and $before -match '(?i)\b(AS|DO)\s*$') { $bodyTag = $v; $pos = $m.Index + $m.Length; continue }
            if ($v -eq $bodyTag) { $bodyTag = $null; $pos = $m.Index + $m.Length; continue }
            $end = $Src.IndexOf($v, $m.Index + $v.Length, [StringComparison]::Ordinal)
            $pos = if ($end -lt 0) { $Src.Length } else { $end + $v.Length }
            continue
        }
        $pos = $m.Index + $m.Length
    }
    $out
}

# bash: zeilenweise mit Quote-Zustand ueber Zeilen und Here-Doc-Erkennung (Rumpf bis zur Endmarke ist kein Kommentar).
function Get-ShComments([string]$Src) {
    $lines = $Src -split "`r?`n"
    $q = $null; $keep = $false; $hereEnd = $null; $hereDash = $false; $head = $true
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $l = $lines[$n]
        if ($hereEnd) {
            $cmp = if ($hereDash) { $l.TrimStart("`t") } else { $l }
            if ($cmp -eq $hereEnd) { $hereEnd = $null }
            continue
        }
        if ($n -eq 0 -and $l.StartsWith('#!')) { continue }
        $code = New-Object System.Text.StringBuilder   # Text ausserhalb von Quotes, dazu die Endmarke von <<'EOF'
        for ($i = 0; $i -lt $l.Length; $i++) {
            $c = $l[$i]
            if ($q -eq "'") { if ($c -eq "'") { $q = $null }; if ($keep) { [void]$code.Append($c) }; continue }
            if ($q -eq '"') { if ($c -eq '\') { $i++; continue }; if ($c -eq '"') { $q = $null }; if ($keep) { [void]$code.Append($c) }; continue }
            if ($c -eq '\') { $i++; continue }
            if ($c -eq "'" -or $c -eq '"') { $keep = ($code.ToString() -match '<<-?\s*$'); $q = $c; [void]$code.Append($c); continue }
            if ($c -eq '#') {
                $prev = if ($i -gt 0) { $l[$i - 1] } else { ' ' }
                if ([char]::IsWhiteSpace($prev) -or $prev -eq ';') {
                    $isHead = $head -and ($code.ToString().Trim() -eq '')
                    New-C ($n + 1) $l.Substring($i + 1) $isHead
                    break
                }
            }
            [void]$code.Append($c)
        }
        $codeText = $code.ToString()
        if ($codeText.Trim() -ne '') { $head = $false }
        $m = [regex]::Match($codeText, '<<(-?)\s*([''"]?)([A-Za-z_][A-Za-z0-9_]*)\2')
        if ($m.Success -and $codeText -notmatch '<<<') { $hereEnd = $m.Groups[3].Value; $hereDash = ($m.Groups[1].Value -eq '-') }
    }
}

# JS: ein "/" ist Regex-Literal, wenn davor ein Operator, eine oeffnende Klammer, return/typeof oder nichts steht.
$jsTokRx = [regex]'//[^\n]*|/\*[\s\S]*?\*/|''(?:[^''\\\n]|\\[\s\S])*''|"(?:[^"\\\n]|\\[\s\S])*"|`(?:[^`\\$]|\\[\s\S]|\$(?!\{)|\$\{(?:[^{}`]|`(?:[^`\\]|\\[\s\S])*`|\{[^{}]*\})*\})*`|/(?![/*])(?:[^/\\\[\n]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/'
function Test-JsRegexStart([string]$Src, [int]$Off) {
    $k = $Off - 1
    while ($k -ge 0 -and [char]::IsWhiteSpace($Src[$k])) { $k-- }
    if ($k -lt 0) { return $true }
    if ('(,=:[!&|?{};+-*%<>~^'.IndexOf($Src[$k]) -ge 0) { return $true }
    $w = $k
    while ($w -ge 0 -and [char]::IsLetter($Src[$w])) { $w-- }
    $word = $Src.Substring($w + 1, $k - $w)
    return ($word -eq 'return' -or $word -eq 'typeof')
}
function Get-JsComments([string]$Src) {
    $out = New-Object System.Collections.Generic.List[object]
    $starts = Get-LineStarts $Src
    $pos = 0; $head = $true
    while ($pos -lt $Src.Length) {
        $m = $jsTokRx.Match($Src, $pos)
        if (-not $m.Success) { break }
        if ($head -and $m.Index -gt $pos -and -not [string]::IsNullOrWhiteSpace($Src.Substring($pos, $m.Index - $pos))) { $head = $false }
        $v = $m.Value
        if ($v.StartsWith('//')) { Add-CommentToken $out $starts $m.Index $v.Substring(2) $head; $pos = $m.Index + $m.Length; continue }
        if ($v.StartsWith('/*')) { Add-CommentToken $out $starts $m.Index ($v.Substring(2, $v.Length - 4) -replace '(?m)^\s*\*(?!/)', '') $head; $pos = $m.Index + $m.Length; continue }
        $head = $false
        if ($v.StartsWith('/') -and -not (Test-JsRegexStart $Src $m.Index)) { $pos = $m.Index + 1; continue }
        $pos = $m.Index + $m.Length
    }
    $out
}

function Get-Comments([string]$Lang, [string]$Src) {
    switch ($Lang) {
        'ps'  { @(Get-PsComments $Src) }
        'sql' { @(Get-SqlComments $Src) }
        'sh'  { @(Get-ShComments $Src) }
        'js'  { @(Get-JsComments $Src) }
    }
}

# --- Regeln je Kommentarzeile ----------------------------------------------------------------------------------
# Testdaten-Daten ("am 30.06.2025", "Depot-Stand 31.12.2026", "seit 01.01.2027"), Ablauf-Phasen ("Phase 1: Baseline") und
# Kalenderwochen-Logik ("KW 53") sind Fakten und treffen nicht; ein Datum zaehlt nur als Anlass (Befund/Fund + Datum).
$dateRx = '(20\d\d-[01]\d-[0-3]\d|[0-3]?\d\.[01]?\d\.20\d\d)'
$ropt = [System.Text.RegularExpressions.RegexOptions]
$verlaufRx = [regex]::new(("(?i:\b(Befund|Fund)\s+$dateRx)|(?i:\bneu\s+(seit|ab)\b)|(?i:\b(seit|bis)\s+v\d+\.\d+)|" +
    '\(v\d+\.\d+\.\d+\)|\bKW\s?\d{1,2}\s+(Fund|Befund|Sprint)\b|\(KW\s?\d{1,2}\)|\bPhase\s+[A-Z]\b|' +
    '(?i:\b(fr(ü|ue)her|vormals|ehemals)\s+(war|hie(ß|ss)|stand|lief|galt|gab|wurde|wurden|kam|lag|ging)\b)|' +
    '(?i:\b(war|hie(ß|ss)|stand|lief|galt|wurde)\s+(hier\s+)?fr(ü|ue)her\b)'), $ropt::Compiled)
# Arbeits-Marken und Plan-Verweise. Andere Pfade unter .local/ sind Fakten (Zustandsdateien) und treffen nicht; "Paket <n>" trifft
# nur in Klammern oder als "n/m", weil "je Paket 1 Datei" ein Fakt ist; "Plan" nur vor einem Namen mit Bindestrich oder in
# Sternen, weil der Plan des Haushalts ein Fachbegriff ist. Migrations-Verweise (core:V012) sind Adressen und treffen nicht.
$workMarkRx = [regex]::new(("(?i:\b(Owner|Owner-\w+|Abnahme|Entscheid\w*|decision|Lauf)\s+$dateRx)|\bOwner-(Runde|Wunsch)\b|\b(Probelauf|Live)-(Fund|Befund)\b|" +
    '\(([^()]*,\s*)?Paket\s+[A-Z]?\d+[a-z]?\)|\bPaket\s+\d+/\d+\b|\bEinwand\s+\d+\b|\bPr(ü|ue)fliste\s+Nr\.?\s*\d+|' +
    '\bBug\s+[A-Z]\d+\b|\bPlan\s+([a-z0-9]+(-[a-z0-9]+)+|\*[^*]+\*)|\.claude/plans/|\.local/(handover|plans?)/'), $ropt::Compiled)
# Nummern einer Abnahme-Liste wie "(P5)" oder "(B10)"; neben einem Test-Verweis ist "(P5)" die Eigenschaft im Test, also eine Adresse.  comment-lint: ok Regeltext
$listNoRx = [regex]::new('\((P|B)\d{1,2}\)', $ropt::Compiled)
# Auskommentierter Code: nur eindeutige Formen. Ein Beispiel im Kommentar ist eingerueckt (ab drei Leerzeichen) und trifft nicht,
# ebenso eine Parameter-Beschreibung "$Name = Prosa".
$codeRx = @{
    ps  = [regex]::new('^ {0,2}(\$[A-Za-z_][\w:.]*\s*(=|\+=|-=)\s*\S+\s*;?\s*$|(if|elseif|foreach|while|for|switch)\s*\(.*\)\s*\{\s*$|[{}]\s*$)', $ropt::Compiled)
    sql = [regex]::new('^ {0,2}((SELECT\s.+\sFROM\s|INSERT\s+INTO\s|UPDATE\s+[\w.]+\s+SET\s|DELETE\s+FROM\s|PERFORM\s+[\w.]+\(|RETURN\s+\S|RAISE\s+(EXCEPTION|NOTICE|WARNING)\s+''|ALTER\s+TABLE\s|DROP\s+(TABLE|FUNCTION|INDEX|VIEW)\s).*;\s*$|[a-z_][a-z0-9_]*\s*:=\s*.+;\s*$)', $ropt::Compiled)
    sh  = [regex]::new('^ {0,2}((local\s+|export\s+)?[A-Za-z_][A-Za-z0-9_]*=("|''|\$|[A-Za-z0-9/])\S*\s*$|(fi|done|esac|then|else)\s*$|if\s+\[.*\]\s*;\s*then\s*$)', $ropt::Compiled)
    js  = [regex]::new('^ {0,2}((const|let|var)\s+\w+\s*=.*;\s*$|[\w.$\[\]''"]+\s*\(.*\)\s*;\s*$|[{}]\s*;?\s*$)', $ropt::Compiled)
}
$todoRx = [regex]::new('(?<![''"])\b(TODO|FIXME)\b(?![''"])', $ropt::Compiled)
$todoOkRx = [regex]::new('\b(TODO|FIXME)\s*(\(\S[^)]*\)|:?\s*(wenn|sobald|nach|falls|bei)\b)', $ropt::Compiled)
$capsRx = [regex]::new('(?<![A-Za-zÄÖÜäöüß_-])(NIE|NIEMALS|NICHT|IMMER|MUSS|MÜSSEN|MUESSEN|KEIN|KEINE|KEINEN|NUR|ACHTUNG|WICHTIG|VORSICHT|ZUERST|SOFORT|OHNE|EXAKT|GENAU|DARF|DÜRFEN|DUERFEN|SOLL|BEWUSST|PFLICHT|VERBOTEN|JEDE|JEDER|JEDES|ALLE|NEVER|ALWAYS|MUST|IMPORTANT)(?![A-Za-zÄÖÜäöüß_-])', $ropt::Compiled)
$okRx = [regex]::new('comment-lint:\s*ok\s+\S', $ropt::Compiled)   # ohne Grund gilt die Ausnahme nicht

function Get-LineRules([string]$Lang, $C) {
    $t = $C.Text
    if ($okRx.IsMatch($t)) { return @() }
    $r = @()
    if ($verlaufRx.IsMatch($t) -or $workMarkRx.IsMatch($t) -or ($listNoRx.IsMatch($t) -and $t -notmatch 'tests?[/_]')) { $r += 'verlauf' }
    if (-not $C.Head -and $codeRx[$Lang].IsMatch($t)) { $r += 'code' }
    if ($todoRx.IsMatch($t) -and -not $todoOkRx.IsMatch($t)) { $r += 'todo' }
    if ($capsRx.IsMatch($t)) { $r += 'caps' }
    $r
}

# Gibt es die im Kopf genannte Quelle? Als Repo-Pfad oder als Dateiname irgendeiner getrackten .ps1.
$script:trackedPs1 = $null
function Test-RepoScript([string]$Name) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $Name) -PathType Leaf) { return $true }
    if ($null -eq $script:trackedPs1) { $script:trackedPs1 = @{}; foreach ($p in (Invoke-Git @('ls-files', '*.ps1'))) { $script:trackedPs1[(Split-Path $p -Leaf)] = $true } }
    return $script:trackedPs1.ContainsKey((Split-Path $Name -Leaf))
}

# Pflichtteile tragender Koepfe neuer Dateien: liefert Liste fehlender Teile.
function Get-HeadGaps([string]$Path, [string]$Lang, $Comments) {
    $headText = (@($Comments | Where-Object { $_.Head }) | ForEach-Object { $_.Text }) -join "`n"
    $gaps = @()
    if ($Lang -eq 'ps' -and $Path -match '(^|/)scripts/' -and $Path -notmatch '/lib/') {
        if ($headText -notmatch '(?i)(aufruf|usage|\.ps1\b)') { $gaps += 'Aufruf-Beispiel' }
        if ($headText -notmatch '(?i)exit') { $gaps += 'Exit-Code' }
    }
    if ($Lang -eq 'sql' -and $Path -match '/R__(fn_[A-Za-z0-9_]+)\.sql$') {
        $name = $Matches[1]
        $hl = @($Comments | Where-Object { $_.Head } | ForEach-Object { $_.Text } | Where-Object { $_ -notmatch '^\s*=+\s*$' -and $_.Trim() })
        $ti = -1
        for ($k = 0; $k -lt $hl.Count; $k++) { if ($hl[$k] -match ('^\s*([a-z0-9_]+\.)?' + [regex]::Escape($name) + '\b')) { $ti = $k; break } }
        if ($ti -lt 0) { $gaps += "Titelzeile '-- $name'" }
        elseif ($ti + 1 -ge $hl.Count) { $gaps += 'Beschreibung unter der Titelzeile' }
    }
    # Inhaltszeilen des Kopfs: ohne Leerzeilen, #Requires und shellcheck-Direktiven.
    $headLines = @($Comments | Where-Object { $_.Head } | ForEach-Object { $_.Text } | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(Requires|shellcheck)\b' })
    if ($Lang -eq 'ps' -and $Path -match '(^|/)packages/[^/]+/build/') {
        if ($headLines.Count -lt 2) { $gaps += 'Kopf mit mindestens zwei Zeilen (was die Datei baut; Ausloeser und Ausgang)' }
    }
    if ($Lang -eq 'sh' -and $Path -match '(^|/)provisioning/lib/([^/]+\.sh)$') {
        $base = $Matches[2]
        if ($headLines.Count -eq 0 -or $headLines[0] -notmatch ('^\s*' + [regex]::Escape($base) + '\s+(—|--|-)\s+\S')) { $gaps += "erste Zeile '# $base — <Zweck>'" }
        if ($headText -notmatch '(?i)sourc(t|ed)') { $gaps += "wer die Datei sourct ('Gesourct von ...')" }
    }
    if ($Lang -eq 'sh' -and $Path -match '(^|/)provisioning/[^/]+\.sh$') {
        if ($headText -notmatch '(?i)(aufruf|usage)') { $gaps += 'Aufruf-Beispiel' }
        if ($headText -notmatch '(?i)exit') { $gaps += 'Exit-Code' }
    }
    foreach ($m in [regex]::Matches($headText, '(?i)Dot-gesourct von\s+([\w./\\-]+\.ps1)')) {
        $src = $m.Groups[1].Value.Replace('\', '/')
        if (-not (Test-RepoScript $src)) { $gaps += "'Dot-gesourct von $src': die Datei gibt es nicht" }
    }
    $gaps
}

# --- Selbst-Asserts: stirbt die Erkennung still, bricht der Lint -----------------------------------------------
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
$selfCases = @(
    @{ l = 'ps';  s = "`$a = 1`n# Befund 2026-01-02 war anders`n"; want = 'verlauf' }
    @{ l = 'ps';  s = "`$h = @'`n# Befund 2026-01-02`n'@`n"; want = '' }
    @{ l = 'sql'; s = "SELECT '-- Stand 2026-01-02';`n"; want = '' }
    @{ l = 'sql'; s = "CREATE FUNCTION f() RETURNS int AS `$`$`nBEGIN -- TODO`nEND `$`$;`n"; want = 'todo' }
    @{ l = 'sh';  s = "cat <<EOF`n# NIE`nEOF`necho x # NIE`n"; want = 'caps' }
    @{ l = 'js';  s = "const u = 'http://x'; // ok`nconst r = /\/\/ KW45/;`n"; want = '' }
)
foreach ($sc in $selfCases) {
    $got = @(foreach ($c in (Get-Comments $sc.l $sc.s)) { Get-LineRules $sc.l $c }) -join ','
    if ($got -ne $sc.want) { Fail "Selbst-Assert ($($sc.l)): erwartet [$($sc.want)], gefunden [$got] -- Erkennung defekt" }
}
if ($fails -gt 0) { Write-Host "comment_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

# --- Ziel-Zeilen bestimmen: Pfad -> Set geaenderter Zeilen ($null = alle), dazu "neu angelegt" --------------------
function Invoke-Git([string[]]$GitArgs) {
    $o = & git -C $RepoRoot -c core.quotePath=false @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen (Exit $LASTEXITCODE)" }
    $o
}
# PS 5.1: eine stderr-Zeile eines nativen Befehls bricht unter ErrorActionPreference=Stop ab, auch mit 2>$null.
function Get-MergeBase([string]$Ref) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $mb = & git -C $RepoRoot merge-base HEAD $Ref 2>$null; if ($LASTEXITCODE -eq 0) { return [string]$mb } } finally { $ErrorActionPreference = $prev }
    return $null
}
$targets = [ordered]@{}   # path -> HashSet[int] oder $null
$added = @{}
$mode = 'diff'
if ($Files.Count -gt 0) {
    $mode = 'files'
    foreach ($f in $Files) { $targets[$f] = $null }
} elseif ($All) {
    $mode = 'all'
    foreach ($p in (Invoke-Git @('ls-files'))) { $targets[$p] = $null }
} else {
    if ($Staged) { $diffArgs = @('diff', '--cached') }
    else {
        if (-not $Base) {
            foreach ($ref in 'origin/main', 'main') {
                $mb = Get-MergeBase $ref
                if ($mb) { $Base = $mb; break }
            }
            if (-not $Base) { throw 'Kein Vergleichsstand: weder origin/main noch main erreichbar (-Base <rev> angeben).' }
        }
        else {
            # Gegen die gemeinsame Vorfahrin: eine PR-Basis, die inzwischen weiter ist, braechte sonst ihre eigenen Loeschungen als neue Zeilen.
            $mb = Get-MergeBase $Base
            if ($mb) { $Base = $mb }
        }
        $diffArgs = @('diff', $Base)
    }
    foreach ($p in (Invoke-Git ($diffArgs + @('--name-only', '--diff-filter=A')))) { if ($p) { $added[$p] = $true } }
    $cur = $null; $prevMinus = $false
    foreach ($l in (Invoke-Git ($diffArgs + @('-U0', '--no-color', '--diff-filter=AMR')))) {
        # "+++ " ist nur direkt nach "--- " ein Datei-Kopf; sonst eine hinzugefuegte Zeile, die mit "++ " beginnt.
        $isMinus = $l.StartsWith('--- '); $wasMinus = $prevMinus; $prevMinus = $isMinus
        if ($wasMinus -and $l -match '^\+\+\+ (b/)?(.*)$') { $cur = $Matches[2]; if ($cur -eq '/dev/null') { $cur = $null } elseif (-not $targets.Contains($cur)) { $targets[$cur] = New-Object System.Collections.Generic.HashSet[int] }; continue }
        if ($cur -and $l -match '^@@ -\d+(,\d+)? \+(\d+)(,(\d+))? @@') {
            $start = [int]$Matches[2]; $cnt = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
            for ($k = 0; $k -lt $cnt; $k++) { [void]$targets[$cur].Add($start + $k) }
        }
    }
    if (-not $Staged) {
        foreach ($p in (Invoke-Git @('ls-files', '--others', '--exclude-standard'))) { if ($p) { $targets[$p] = $null; $added[$p] = $true } }
    }
}

# --- Scan -------------------------------------------------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
$scanned = 0
foreach ($p in @($targets.Keys)) {
    $rel = $p.Replace('\', '/')
    if ($mode -ne 'files' -and $rel -match $excludeRx) { continue }
    $lang = Get-Lang $rel
    if (-not $lang) { continue }
    $set = $targets[$p]
    if ($null -ne $set -and $set.Count -eq 0) { continue }
    if ($Staged) { $src = (Invoke-Git @('show', ":$rel")) -join "`n" }
    else {
        $full = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $RepoRoot $p }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $src = [System.IO.File]::ReadAllText($full, $u8)
    }
    $scanned++
    $comments = @(Get-Comments $lang $src)
    foreach ($c in $comments) {
        if ($null -ne $set -and -not $set.Contains($c.Line)) { continue }
        foreach ($rule in (Get-LineRules $lang $c)) { $findings.Add([pscustomobject]@{ File = $rel; Line = $c.Line; Rule = $rule; Text = $c.Text.Trim() }) }
    }
    if ($mode -eq 'files' -or $added.ContainsKey($rel)) {
        foreach ($g in (Get-HeadGaps $rel $lang $comments)) { $findings.Add([pscustomobject]@{ File = $rel; Line = 1; Rule = 'kopf'; Text = "fehlt: $g" }) }
    }
}

if ($Json) { ConvertTo-Json -InputObject @($findings | Select-Object File, Line, Rule) -Compress; exit 0 }
if ($mode -eq 'all') {
    foreach ($g in ($findings | Group-Object Rule | Sort-Object Name)) { Write-Host ("  {0,-8} {1}" -f $g.Name, $g.Count) }
    if ($Verbose) { foreach ($f in $findings) { Write-Host "  $($f.File):$($f.Line) [$($f.Rule)] $($f.Text)" -ForegroundColor DarkGray } }
    Write-Host "comment_lint -All: $($findings.Count) Treffer im Bestand ($scanned Dateien), nur Bericht" -ForegroundColor Yellow
    exit 0
}
$hint = @{ verlauf = 'Herkunft/Verlauf steht in git'; code = 'auskommentierten Code loeschen'; todo = 'TODO mit Ausloeser: TODO(<wann>) oder "TODO wenn ..."'
           caps = 'Betonung in Grossbuchstaben: normal schreiben, harte Verbote werden Lint oder Assert'; kopf = 'tragender Kopf unvollstaendig (.claude/rules/comments.md)' }
foreach ($f in $findings) { Fail "$($f.File):$($f.Line) [$($f.Rule)] $($hint[$f.Rule]) -- $($f.Text)" }
if ($fails -eq 0) { Write-Host "comment_lint: OK ($scanned Datei(en) mit neuen Zeilen geprueft, Modus $mode)" -ForegroundColor Green }
else { Write-Host "comment_lint: $fails Fund(e) in neuen Kommentarzeilen -- Regel .claude/rules/comments.md; Ausnahme mit 'comment-lint: ok <Grund>'" -ForegroundColor Red }
exit $fails
