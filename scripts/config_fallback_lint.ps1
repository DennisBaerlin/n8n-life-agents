#Requires -Version 5.1
# config_fallback_lint.ps1 -- Rueckfall-Werte im Code == Standardwerte der Manifeste (hartes Gate). Leitend ist das Manifest
# (packages/<pkg>/manifest.json .config.<kategorie>.<key>.value): ein anderer Rueckfall wirkt erst, wenn die Zeile fehlt,
# und dann anders als dokumentiert.
# Scan: packages/*/db/**/*.sql ohne migrations/V*.sql (angewandte Migrationen sind eingefroren) und die SQL-/Ausdrucks-Texte der
# gebauten Workflows packages/*/workflows/*.json (Stickies nicht; die Bauquellen deckt build.ps1 -VerifyWorkflows).
# Lese-Formen: core.fn_config_get(paket, kategorie, key), SELECT value FROM core.config, finance.fn_config_eur_in_currency(key,
# standard, ...) und in Ausdruecken .json.<kategorie>.<key> || <wert> (auch ??).
# Rueckfall-Formen: COALESCE(..., <wert>) (auch um einen Vergleich = '<x>'), Zuweisung an eine Variable mit spaeterem
# COALESCE(var, <wert>), var := <wert> oder CASE WHEN var ... ELSE <wert> END, zusammengesetzter Key mit CASE-Rueckfall,
# Schluessel-Schleife ueber eine jsonb-Standardkarte.
# Rot: Rueckfall != Manifest; Key ohne Manifest-Zeile in diesem Paket; ein Lese-Aufruf ohne erkannten Rueckfall, der nicht in
# scripts/build/config_fallback_allowlist.json steht (so faellt eine neue, nicht erkannte Rueckfall-Form auf).
# Ausnahme ohne Eintrag: cron_enable mit Rueckfall 'false' (fail-closed, Kopf von R__fn_config_get.sql). Kategorie model prueft
# dieser Lint nicht (config_test 4).
# Allowlist je (where, read, fallback) mit count; reason 'none:<warum>' (kein Rueckfall), 'differs:<warum>' (bewusst anders).
# Rot dort: reason passt nicht zum Rueckfall, doppelter Eintrag, count weicht ab, Eintrag ohne Fund. Selbst- und Scope-Asserts
# (Erkennung defekt, nichts gelesen) sind ebenfalls Fehler.
# Aufruf: .\scripts\config_fallback_lint.ps1 [-Verbose] [-Baseline] [-Root <Baum>]   (-Root nur fuer den Test)
#   -Baseline druckt das Allowlist-Geruest (Exit 0), -Verbose listet jede Lese-Stelle.
# Test: scripts/dev/config_fallback_lint_test.ps1. Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root, [switch]$Baseline, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path.TrimEnd('\', '/')
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
function Get-Rel([string]$Full) { return $Full.Substring($Root.Length + 1).Replace('\', '/') }

# Helfer, die selbst Config lesen und den Rueckfall als Argument bekommen: Name -> Paket + Kategorie.
$helpers = @{ 'fn_config_eur_in_currency' = @{ pkg = 'finance'; cat = 'finance' } }

# --- Text-Werkzeuge -------------------------------------------------------------------------------------------------
# SQL-Kommentare raus (quote-aware), Zeilenumbrueche bleiben.
function Remove-SqlComment([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $s.Length; $inStr = $false
    while ($i -lt $n) {
        $c = $s[$i]
        if ($inStr) { [void]$sb.Append($c); if ($c -eq "'") { $inStr = $false }; $i++; continue }
        if ($c -eq "'") { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '-' -and $i + 1 -lt $n -and $s[$i + 1] -eq '-') { while ($i -lt $n -and $s[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $s[$i + 1] -eq '*') {
            $e = $s.IndexOf('*/', $i + 2, [System.StringComparison]::Ordinal); if ($e -lt 0) { $e = $n - 2 }
            for ($k = $i; $k -lt $e + 2; $k++) { if ($s[$k] -eq "`n") { [void]$sb.Append("`n") } }
            $i = $e + 2; continue
        }
        [void]$sb.Append($c); $i++
    }
    return $sb.ToString()
}
# Gleiche Laenge wie der Text, Inhalt der '...'-Literale als '_' -> Klammern und Kommas lassen sich sicher zaehlen.
function Get-Mask([string]$s) {
    $a = $s.ToCharArray(); $inStr = $false
    for ($i = 0; $i -lt $a.Length; $i++) {
        if ($a[$i] -eq "'") { $inStr = -not $inStr; continue }
        if ($inStr) { $a[$i] = '_' }
    }
    return [string]::new($a)
}
function Find-Close([string]$Mask, [int]$Open) {
    $d = 0
    for ($i = $Open; $i -lt $Mask.Length; $i++) {
        if ($Mask[$i] -eq '(') { $d++ } elseif ($Mask[$i] -eq ')') { $d--; if ($d -eq 0) { return $i } }
    }
    return $Mask.Length
}
function Find-OpenBefore([string]$Mask, [int]$Pos) {
    $d = 0
    for ($i = $Pos - 1; $i -ge 0; $i--) {
        $c = $Mask[$i]
        if ($c -eq ')') { $d++ } elseif ($c -eq '(') { if ($d -eq 0) { return $i }; $d-- } elseif ($c -eq ';' -and $d -eq 0) { return -1 }
    }
    return -1
}
# Argumente zwischen $Open und der passenden Klammer: Liste @{start; end} (end exklusiv).
function Get-ArgSpans([string]$Mask, [int]$Open) {
    $close = Find-Close $Mask $Open
    $out = New-Object System.Collections.Generic.List[object]
    $d = 0; $from = $Open + 1
    for ($i = $Open + 1; $i -lt $close; $i++) {
        $c = $Mask[$i]
        if ($c -eq '(' -or $c -eq '[') { $d++ } elseif ($c -eq ')' -or $c -eq ']') { $d-- }
        elseif ($c -eq ',' -and $d -eq 0) { $out.Add(@{ start = $from; end = $i }); $from = $i + 1 }
    }
    $out.Add(@{ start = $from; end = $close })
    return , $out.ToArray()
}
function Get-Span([string]$Code, $Span) { return $Code.Substring($Span.start, $Span.end - $Span.start).Trim() }
# Literaler Rueckfall -> Wert, sonst $null ('' zaehlt nicht: es reicht den fehlenden Wert nur weiter).
$litRx = "^(?:'((?:[^']|'')*)'|(-?\d+(?:\.\d+)?)|(true|false|TRUE|FALSE))(?:\s*::\s*[a-z_]+)?$"
function Get-LiteralValue([string]$Text) {
    $m = [regex]::Match($Text.Trim(), $litRx)
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { if ($m.Groups[1].Value -eq '') { return $null }; return $m.Groups[1].Value }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    return $m.Groups[3].Value.ToLowerInvariant()
}

# --- Rueckfall zu einer Lese-Stelle ------------------------------------------------------------------------------------
# Liefert @{kind='literal'; value} | @{kind='case'; var; map; else} | $null.
function Find-CoalesceFallback([string]$Code, [string]$Mask, [int]$Pos) {
    $p = $Pos
    while ($true) {
        $open = Find-OpenBefore $Mask $p
        if ($open -lt 0) { return $null }
        $name = [regex]::Match($Mask.Substring(0, $open), '([A-Za-z_]\w*)\s*$').Groups[1].Value
        $p = $open
        if ($name -ne 'COALESCE') { continue }
        $spans = Get-ArgSpans $Mask $open
        $at = -1
        for ($i = 0; $i -lt $spans.Count; $i++) { if ($Pos -ge $spans[$i].start -and $Pos -lt $spans[$i].end) { $at = $i } }
        if ($at -lt 0) { continue }
        for ($i = $at + 1; $i -lt $spans.Count; $i++) {
            $t = Get-Span $Code $spans[$i]
            $cm = [regex]::Match($t, "(?s)^CASE\s+(\w+)\s+(WHEN\s.*?)\s+ELSE\s+(\S+)\s+END$")
            if ($cm.Success) {
                $map = @{}
                foreach ($w in [regex]::Matches($cm.Groups[2].Value, "WHEN\s+'([^']*)'\s+THEN\s+(\S+)")) { $map[$w.Groups[1].Value] = Get-LiteralValue $w.Groups[2].Value }
                return @{ kind = 'case'; var = $cm.Groups[1].Value; map = $map; else = (Get-LiteralValue $cm.Groups[3].Value) }
            }
            $v = Get-LiteralValue $t
            if ($null -eq $v) { continue }
            # COALESCE(<lesen> = 'x', true|false): der Rueckfall gilt dem Vergleich -> auf den Config-Wert umrechnen.
            $argMask = $Mask.Substring($spans[$at].start, $spans[$at].end - $spans[$at].start)
            $eq = [regex]::Match($argMask, "(?<![<>!])=\s*'(_*)'\s*$")
            if ($eq.Success -and ($v -eq 'true' -or $v -eq 'false')) {
                $x = $Code.Substring($spans[$at].start + $eq.Groups[1].Index, $eq.Groups[1].Length)
                if ($x -eq 'true') { return @{ kind = 'literal'; value = $v } }
                if ($x -eq 'false') { return @{ kind = 'literal'; value = $(if ($v -eq 'true') { 'false' } else { 'true' }) } }
            }
            return @{ kind = 'literal'; value = $v }
        }
    }
}
function Find-VariableFallback([string]$Code, [string]$Mask, [int]$Pos) {
    # Die Variable gehoert zum Befehl der Lese-Stelle: gesucht wird nur zwischen den ';' um sie herum (maskiert, ein ';' im Literal zaehlt nicht).
    $cut = if ($Pos -gt 0) { $Mask.LastIndexOf(';', $Pos - 1) } else { -1 }
    $end = $Mask.IndexOf(';', $Pos); if ($end -lt 0) { $end = $Mask.Length }
    $m = [regex]::Match($Code.Substring($cut + 1, $Pos - $cut - 1), '(?is)(?:^|[\s(])([a-z]_\w+)(?:\s+(?:constant\s+)?[a-z]+(?:\([\d, ]*\))?(?:\[\])?)?\s*:=')
    if (-not $m.Success) { $m = [regex]::Match($Mask.Substring($cut + 1, $end - $cut - 1), '(?i)(?<!INSERT\s+)\bINTO\s+(?:STRICT\s+)?([a-z]_\w+)\b') }
    if (-not $m.Success) { return $null }
    $var = [regex]::Escape($m.Groups[1].Value)
    $rest = $Code.Substring($end)
    $next = $rest.IndexOf('CREATE OR REPLACE', [System.StringComparison]::OrdinalIgnoreCase)
    if ($next -ge 0) { $rest = $rest.Substring(0, $next) }
    $lit = "('(?:[^']|'')*'|-?\d+(?:\.\d+)?|true|false)"
    $best = $null
    foreach ($rx in @("(?i)COALESCE\(\s*$var(?:\s*::\s*[a-z]+)?\s*,\s*$lit", "(?i)(?<![\w.])$var\s*:=\s*$lit\s*;", "(?i)CASE\s+WHEN\s+$var\b[^;]*?\bELSE\s+$lit\s+END")) {
        $h = [regex]::Match($rest, $rx)
        if ($h.Success -and ($null -eq $best -or $h.Index -lt $best.Index)) { $best = $h }
    }
    if ($null -eq $best) { return $null }
    $v = Get-LiteralValue $best.Groups[1].Value
    if ($null -eq $v) { return $null }
    return @{ kind = 'literal'; value = $v }
}

# Das SELECT derselben Klammer-Ebene vor $Pos; -1, wenn dort keines steht (z. B. DELETE FROM).
function Find-SelectBefore([string]$Mask, [int]$Pos) {
    $tokens = [regex]::Matches($Mask.Substring(0, $Pos), '(?i)\bSELECT\b|\bDELETE\b|[();]')
    $d = 0
    for ($i = $tokens.Count - 1; $i -ge 0; $i--) {
        $t = $tokens[$i].Value
        if ($t -eq ')') { $d++ }
        elseif ($t -eq '(') { if ($d -eq 0) { return -1 }; $d-- }
        elseif ($d -ne 0) { continue }
        elseif ($t -eq 'SELECT') { return $tokens[$i].Index }
        else { return -1 }
    }
    return -1
}

# --- Scan eines SQL-Textes ---------------------------------------------------------------------------------------------
# Funde: @{pkg (oder $null = Ausdruck); cat; key (oder $null); fallback (Text oder $null = keiner); label}
function Get-SqlReads([string]$Sql) {
    $code = Remove-SqlComment $Sql
    $mask = Get-Mask $code
    $out = New-Object System.Collections.Generic.List[object]
    function Add-Read($Pkg, $Cat, $Key, $Fallback, $Label) { $out.Add(@{ pkg = $Pkg; cat = $Cat; key = $Key; fallback = $Fallback; label = $Label }) }
    function Add-Resolved($Pkg, $Cat, $KeyExpr, [int]$Pos) {
        $fb = Find-CoalesceFallback $code $mask $Pos
        if ($null -eq $fb) { $fb = Find-VariableFallback $code $mask $Pos }
        $key = $null
        $lk = [regex]::Match($KeyExpr, "^'([^']*)'$")
        if ($lk.Success) { $key = $lk.Groups[1].Value }
        $label = "$Cat.$(if ($null -ne $key) { $key } else { $KeyExpr })"
        if ($null -ne $key) {
            Add-Read $Pkg $Cat $key $(if ($null -ne $fb -and $fb.kind -eq 'literal') { $fb.value } else { $null }) $label
            return
        }
        # 'praefix' || var || 'suffix' mit CASE var WHEN ... als Rueckfall
        $cc = [regex]::Match($KeyExpr, "^'([^']*)'\s*\|\|\s*(\w+)\s*\|\|\s*'([^']*)'$")
        if ($cc.Success -and $null -ne $fb -and $fb.kind -eq 'case' -and $fb.var -eq $cc.Groups[2].Value) {
            $pre = $cc.Groups[1].Value; $suf = $cc.Groups[3].Value
            foreach ($w in $fb.map.Keys) { Add-Read $Pkg $Cat "$pre$w$suf" $fb.map[$w] "$Cat.$pre$w$suf" }
            $out.Add(@{ pkg = $Pkg; cat = $Cat; key = $null; prefix = $pre; suffix = $suf; except = @($fb.map.Keys); fallback = $fb.else; label = "$Cat.$pre*$suf" })
            return
        }
        # for <var> in select jsonb_object_keys(<karte>) mit <karte> constant jsonb := '{...}'
        if ($KeyExpr -match '^\w+$') {
            $loop = [regex]::Match($code, "(?i)\bFOR\s+$KeyExpr\s+IN\s+SELECT\s+jsonb_object_keys\((\w+)\)")
            if ($loop.Success) {
                $map = [regex]::Match($code, "(?s)\b$($loop.Groups[1].Value)\s+(?:constant\s+)?jsonb\s*:=\s*'(\{[^']*\})'")
                if ($map.Success) {
                    foreach ($pr in (ConvertFrom-Json -InputObject $map.Groups[1].Value).PSObject.Properties) { Add-Read $Pkg $Cat $pr.Name ([string]$pr.Value) "$Cat.$($pr.Name)" }
                    return
                }
            }
        }
        Add-Read $Pkg $Cat $null $null $label
    }
    foreach ($m in [regex]::Matches($mask, '(?<![\w])(?:core\.)?fn_config_get\s*\(')) {
        $before = $mask.Substring(0, $m.Index)
        if ($before -match '(?i)(FUNCTION\s+(IF\s+EXISTS\s+)?|to_regprocedure\(\s*''_*)$') { continue }
        $spans = Get-ArgSpans $mask ($m.Index + $m.Length - 1)
        if ($spans.Count -ne 3) { continue }
        $a = @($spans | ForEach-Object { Get-Span $code $_ })
        if ($a[0] -match '^p_\w+\s+text$') { continue }
        $pm = [regex]::Match($a[0], "^'([^']*)'$")
        $cm = [regex]::Match($a[1], "^'([^']*)'$")
        if (-not $cm.Success) { $out.Add(@{ pkg = $null; cat = $a[1]; key = $null; fallback = $null; label = "$($a[1]).$($a[2])" }); continue }
        # Aufruf im Helfer selbst: der Rueckfall steht bei dessen Aufrufern.
        $fnAt = [regex]::Matches($code.Substring(0, $m.Index), '(?i)CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:\w+\.)?(\w+)')
        if ($fnAt.Count -and $helpers.ContainsKey($fnAt[$fnAt.Count - 1].Groups[1].Value) -and $a[2] -notmatch "^'") { continue }
        Add-Resolved $(if ($pm.Success) { $pm.Groups[1].Value } else { $null }) $cm.Groups[1].Value $a[2] $m.Index
    }
    # Jedes SELECT, das aus core.config die Spalte value liest; was sich nicht aufloesen laesst, wird gemeldet statt uebergangen.
    foreach ($m in [regex]::Matches($mask, '(?i)\b(?:FROM|JOIN)\s+core\.config\b(?![\w.])')) {
        $sel = Find-SelectBefore $mask $m.Index
        if ($sel -lt 0) { continue }
        if ($mask.Substring($sel, $m.Index - $sel) -notmatch '(?i)(?<![\w])(?:[a-z_]\w*\.)?value\b') { continue }
        $fnAt = [regex]::Matches($code.Substring(0, $sel), '(?i)CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:\w+\.)?(\w+)')
        if ($fnAt.Count -and $fnAt[$fnAt.Count - 1].Groups[1].Value -eq 'fn_config_get') { continue }   # das Lesefenster selbst
        $end = $m.Index + $m.Length; $d = 0
        while ($end -lt $mask.Length) {
            $c = $mask[$end]
            if ($c -eq '(') { $d++ } elseif ($c -eq ')') { if ($d -eq 0) { break }; $d-- } elseif ($c -eq ';' -and $d -eq 0) { break }
            $end++
        }
        $where = $code.Substring($sel, $end - $sel)
        $cm = [regex]::Match($where, "(?<![\w])(?:\w+\.)?category\s*=\s*'([^']*)'")
        $km = [regex]::Match($where, "(?<![\w.])(?:\w+\.)?key\s*=\s*('[^']*'|[\w.]+)")
        if ($cm.Success -and $km.Success) { Add-Resolved $null $cm.Groups[1].Value $km.Groups[1].Value $sel; continue }
        $cat = if ($cm.Success) { $cm.Groups[1].Value } else { '*' }
        Add-Read $null $cat $null $null "core.config.$cat.*"
    }
    foreach ($h in $helpers.Keys) {
        foreach ($m in [regex]::Matches($mask, "(?<![\w])(?:\w+\.)?$h\s*\(")) {
            $spans = Get-ArgSpans $mask ($m.Index + $m.Length - 1)
            if ($spans.Count -lt 2) { continue }
            $k = [regex]::Match((Get-Span $code $spans[0]), "^'([^']*)'$")
            if (-not $k.Success) { continue }
            Add-Read $helpers[$h].pkg $helpers[$h].cat $k.Groups[1].Value (Get-LiteralValue (Get-Span $code $spans[1])) "$($helpers[$h].cat).$($k.Groups[1].Value)"
        }
    }
    return $out.ToArray()
}
# JS in n8n-Ausdruecken und Code-Knoten: .json.<kategorie>.<key> || <wert>
function Get-JsReads([string]$Text, $Manifest) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($Text, "\.json\.([a-z_]+)\.([a-z0-9_]+)\s*(?:\|\||\?\?)\s*('(?:[^'\\]|\\.)*'|""(?:[^""\\]|\\.)*""|-?\d+(?:\.\d+)?|true|false)")) {
        $cat = $m.Groups[1].Value; $key = $m.Groups[2].Value
        if (-not $Manifest.ContainsKey("$cat.$key")) { continue }
        $v = $m.Groups[3].Value.Trim("'", '"')
        if ($v -eq '') { continue }
        $out.Add(@{ pkg = $null; cat = $cat; key = $key; fallback = $v; label = "$cat.$key" })
    }
    return $out.ToArray()
}
function Test-SameValue([string]$A, [string]$B) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $x = [decimal]0; $y = [decimal]0
    $style = [System.Globalization.NumberStyles]::Float   # ohne Tausender-Zeichen: die Liste '7,21' ist nicht die Zahl 721
    if ([decimal]::TryParse($A, $style, $inv, [ref]$x) -and [decimal]::TryParse($B, $style, $inv, [ref]$y)) { return $x -eq $y }
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

# --- Selbst-Asserts ----------------------------------------------------------------------------------------------------
$self = @(
    @{ sql = "v := COALESCE(NULLIF(core.fn_config_get('core','a','k'), '')::int, 30);";                       want = 'a.k=30' }
    @{ sql = "v := COALESCE(NULLIF(substring(COALESCE(core.fn_config_get('core','a','k'), '') FROM '^\s*(\d+)'), '')::int, 2);"; want = 'a.k=2' }
    @{ sql = "SELECT COALESCE(core.fn_config_get('core','a','k') = 'true', false);";                          want = 'a.k=false' }
    @{ sql = "v_max := core.fn_config_get('core','a','k')::int;`nIF x > COALESCE(v_max, 7) THEN";             want = 'a.k=7' }
    @{ sql = "SELECT COALESCE((SELECT value FROM core.config WHERE category='a' AND key='k'),'false') AS g;"; want = 'a.k=false' }
    @{ sql = "IF core.fn_config_get('core','a','k') IS DISTINCT FROM 'true' THEN";                            want = 'a.k=-' }
    @{ sql = "-- core.fn_config_get('core','a','k')`nSELECT finance.fn_config_eur_in_currency('k', 500, c, d);"; want = 'finance.k=500' }
    @{ sql = "r := COALESCE(core.fn_config_get('f','a','r_' || b || '_x')::numeric, CASE b WHEN 'u' THEN 1.5 ELSE 2 END);"; want = 'a.r_*_x=2;a.r_u_x=1.5' }
    @{ sql = "v_def constant jsonb := '{`"s`":900}';`nFOR v_k IN SELECT jsonb_object_keys(v_def) LOOP v_t := core.fn_config_get('core','w', v_k);"; want = 'w.s=900' }
    @{ sql = "IF core.fn_config_get('core','a','k')::int > 5 THEN x := 1; END IF;`nSELECT count(*) INTO v_cnt FROM t;`nRETURN COALESCE(v_cnt, 60);"; want = 'a.k=-' }
    @{ sql = "v_w := core.fn_config_get('core','a','k')::int;`nx := coalesce(v_w, 99);";                      want = 'a.k=99' }
    @{ sql = "SELECT value AS w FROM core.config WHERE category='a' AND key='k';";                             want = 'a.k=-' }
    @{ sql = "x := COALESCE((SELECT NULLIF(c.value,'')::int FROM core.config c WHERE c.category='a' AND c.key='k'), 99);"; want = 'a.k=99' }
    @{ sql = "SELECT value FROM core.config WHERE category = v_cat; DELETE FROM core.config WHERE value = 'x';"; want = 'core.config.*.*=-' }
)
foreach ($s in $self) {
    $got = (@(Get-SqlReads $s.sql | ForEach-Object { "$($_.label)=$(if ($null -ne $_.fallback) { $_.fallback } else { '-' })" }) | Sort-Object) -join ';'
    if ($got -ne $s.want) { Fail "Selbst-Assert: '$($s.sql)' -> erwartet '$($s.want)', gefunden '$got' -- Erkennung defekt" }
}
if ($fails -gt 0) { Write-Host "config_fallback_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

# --- Manifeste ---------------------------------------------------------------------------------------------------------
$manifest = @{}   # "kategorie.key" -> @{pkg; value}  (core.config ist je (category,key) eindeutig)
foreach ($pkgDir in (Get-ChildItem -LiteralPath (Join-Path $Root 'packages') -Directory)) {
    $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
    if (-not (Test-Path $mfPath)) { continue }
    $mf = [System.IO.File]::ReadAllText($mfPath, $u8) | ConvertFrom-Json
    if ($null -eq $mf.config) { continue }
    foreach ($cat in $mf.config.PSObject.Properties) {
        if ($cat.Name -eq '_comment') { continue }
        foreach ($k in $cat.Value.PSObject.Properties) {
            if ($k.Name -eq '_comment') { continue }
            $manifest["$($cat.Name).$($k.Name)"] = @{ pkg = [string]$mf.name; value = [string]$k.Value.value }
        }
    }
}
if ($manifest.Count -eq 0) { Fail 'keine Manifest-Config gelesen -- Scan tot (Pfad?)' }

# --- Scan --------------------------------------------------------------------------------------------------------------
$reads = New-Object System.Collections.Generic.List[object]   # Fund + .where
$sqlCount = 0
foreach ($f in (Get-ChildItem (Join-Path $Root 'packages') -Recurse -File -Filter '*.sql')) {
    $rel = Get-Rel $f.FullName
    if ($rel -notmatch '^packages/[^/]+/db/' -or $rel -match '/migrations/V\d+__') { continue }
    $sqlCount++
    $text = [System.IO.File]::ReadAllText($f.FullName, $u8)
    if ($text -notmatch 'fn_config_|core\.config') { continue }
    foreach ($r in (Get-SqlReads $text)) { $r.where = $rel; $reads.Add($r) }
}
$wfCount = 0
foreach ($pkgDir in (Get-ChildItem -LiteralPath (Join-Path $Root 'packages') -Directory)) {
    $wfDir = Join-Path $pkgDir.FullName 'workflows'
    if (-not (Test-Path $wfDir)) { continue }
    foreach ($file in (Get-ChildItem $wfDir -Filter '*.json' -File)) {
        $raw = [System.IO.File]::ReadAllText($file.FullName, $u8)
        $wfCount++
        if ($raw -notmatch 'fn_config_|core\.config|\.json\.[a-z_]+\.[a-z0-9_]+') { continue }
        $wf = $raw | ConvertFrom-Json
        foreach ($n in @($wf.nodes)) {
            if ($null -eq $n -or $n.type -eq 'n8n-nodes-base.stickyNote') { continue }
            $where = "$($wf.name) / $($n.name)"
            $q = [string]$n.parameters.query
            if ($q -match 'fn_config_|core\.config') { foreach ($r in (Get-SqlReads $q)) { $r.where = $where; $reads.Add($r) } }
            $params = ConvertTo-Json -InputObject $n.parameters -Depth 40 -Compress
            # ConvertTo-Json (PS 5.1) schreibt ' und & als Unicode-Escape; die Ausdrucks-Muster brauchen die Zeichen.
            $esc = [string][char]92 + 'u00'
            $params = $params.Replace("${esc}27", "'").Replace("${esc}26", '&').Replace('\"', '"')
            foreach ($r in (Get-JsReads $params $manifest)) { $r.where = $where; $reads.Add($r) }
        }
    }
}
if ($sqlCount -eq 0 -or $wfCount -eq 0) { Fail "Scope-Selbst-Assert: $sqlCount SQL-Dateien, $wfCount Workflows -- Scan tot (Pfad?)" }

# --- Abgleich ----------------------------------------------------------------------------------------------------------
# Findings = alles, was nicht gleich dem Manifest ist (Schluessel "where|read|fallback").
$findings = @{}   # key -> @{count; text}
function Add-Finding($R, [string]$Fallback, [string]$Why) {
    $k = "$($R.where)|$($R.label)|$Fallback"
    if ($script:findings.ContainsKey($k)) { $script:findings[$k].count++ }
    else { $script:findings[$k] = @{ count = 1; text = "$($R.where): $($R.label) $Why"; where = $R.where; read = $R.label; fallback = $Fallback } }
}
$same = 0
foreach ($r in $reads) {
    if ($r.ContainsKey('prefix')) {
        $rx = '^' + [regex]::Escape("$($r.cat).$($r.prefix)") + '(.+)' + [regex]::Escape($r.suffix) + '$'
        foreach ($mk in $manifest.Keys) {
            $mm = [regex]::Match($mk, $rx)
            if (-not $mm.Success -or $r.except -contains $mm.Groups[1].Value) { continue }
            if (Test-SameValue $r.fallback $manifest[$mk].value) { $same++ }
            else { Add-Finding $r $r.fallback "ELSE-Rueckfall '$($r.fallback)' != Manifest '$($manifest[$mk].value)' ($mk)" }
        }
        continue
    }
    if ($r.cat -eq 'model') { continue }   # Modell-Zeilen laedt ein Knoten ohne Rueckfall; config_test (4) prueft sie
    if ($null -eq $r.key) { Add-Finding $r '-' 'dynamischer Schluessel ohne erkannten Rueckfall'; continue }
    $id = "$($r.cat).$($r.key)"
    $entry = $manifest[$id]
    if ($null -eq $entry) { Add-Finding $r $(if ($null -ne $r.fallback) { $r.fallback } else { '-' }) 'steht in keinem Manifest (.config)'; continue }
    if ($null -ne $r.pkg -and $r.pkg -ne $entry.pkg) { Add-Finding $r $(if ($null -ne $r.fallback) { $r.fallback } else { '-' }) "liest Paket '$($r.pkg)', die Zeile gehoert '$($entry.pkg)' -- der Rueckfall gaelte immer"; continue }
    if ($null -eq $r.fallback) { Add-Finding $r '-' 'ohne erkannten Rueckfall'; continue }
    if (Test-SameValue $r.fallback $entry.value) { $same++; continue }
    if ($r.cat -eq 'cron_enable' -and $r.fallback -eq 'false') { $same++; continue }
    Add-Finding $r $r.fallback "Rueckfall '$($r.fallback)' != Manifest-Standard '$($entry.value)' (packages/$($entry.pkg)/manifest.json)"
}

if ($Baseline) {
    $entries = foreach ($k in ($findings.Keys | Sort-Object)) {
        $x = $findings[$k]
        [ordered]@{ where = $x.where; read = $x.read; fallback = $x.fallback; count = $x.count; reason = 'TODO' }
    }
    [ordered]@{ _comment = 'reason: none:<warum> | differs:<warum>'; allow = @($entries) } | ConvertTo-Json -Depth 5
    exit 0
}

$alPath = Join-Path $Root 'scripts\build\config_fallback_allowlist.json'
$allow = @{}
if (Test-Path $alPath) {
    foreach ($e in ([System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json).allow) {
        $k = "$($e.where)|$($e.read)|$($e.fallback)"
        $want = if ([string]$e.fallback -eq '-') { '^none:\s*\S' } else { '^differs:\s*\S' }
        if ([string]$e.reason -notmatch $want) { Fail "allowlist: '$k' braucht reason passend zu fallback ($want), ist '$($e.reason)'" }
        if ($allow.ContainsKey($k)) { Fail "allowlist: doppelter Eintrag '$k'"; continue }
        $allow[$k] = [int]$e.count
    }
}
foreach ($k in ($findings.Keys | Sort-Object)) {
    if (-not $allow.ContainsKey($k)) { Fail "$($findings[$k].text) -- Rueckfall ans Manifest angleichen oder begruendet in scripts/build/config_fallback_allowlist.json" }
    elseif ($allow[$k] -ne $findings[$k].count) { Fail "$($findings[$k].text): $($findings[$k].count)x gefunden, allowlist sagt $($allow[$k]) -- count anpassen" }
}
foreach ($k in ($allow.Keys | Sort-Object)) { if (-not $findings.ContainsKey($k)) { Fail "allowlist-ORPHAN '$k' -- nicht (mehr) vorhanden, Eintrag entfernen" } }
if ($Verbose) { foreach ($r in $reads) { Write-Host "  $($r.where): $($r.label) = $(if ($null -ne $r.fallback) { $r.fallback } else { '-' })" -ForegroundColor DarkGray } }
if ($fails -eq 0) { Write-Host "config_fallback_lint: OK ($($reads.Count) Lese-Stellen aus $sqlCount SQL-Dateien + $wfCount Workflows, $same gleich dem Manifest, $($allow.Count) begruendete Ausnahmen)" -ForegroundColor Green }
else { Write-Host "config_fallback_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
