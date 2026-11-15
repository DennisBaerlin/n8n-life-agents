#Requires -Version 5.1
# ui_literal_lint.ps1 -- "kein neuer fest deutscher Nutzertext" (hartes Gate).
# Feste Nutzertexte kommen aus dem Textkatalog (packages/<pkg>/locales/<lang>.json,
# docs/package-contract.md §3.11) in der Sprache des Empfaengers; ein deutsches Literal in einem Telegram-Send, Code-/
# Set-Node oder einer R__-fn waere ein Rueckfall. Mechanik = Ratchet (Baseline-Allowlist): jede vorhandene Stelle
# steht in scripts/build/ui_literal_allowlist.json mit Begruendung. Erlaubte Gruende (reason, ein Nutzertext gehoert in den Katalog):
# model:<warum> = Text fuers Sprachmodell, kein Nutzertext;
# admin:<warum> = RAISE/Konsolen-Meldung fuer den Betreiber; data:<warum> = gespeicherter Inhalt, Originalsprache nach
# Sprachpolitik. Exakt je (Ort, Literal):
#   - Found > Allowlist  -> neuer deutscher Text (FAIL: Katalog-Key nutzen oder mit Begruendung allowlisten);
#   - Found < Allowlist  -> eine Stelle wurde umgestellt (FAIL: Allowlist schrumpfen);
#   - Allowlist-Eintrag ohne Fund -> Orphan (FAIL: entfernen).
# Scan:
#   (a) gebaute Workflows packages/*/workflows/*.json (die Deploy-Vertraege): Telegram-Nodes (alle Text-Parameter inkl.
#       Knopf-Texte und Toasts; callback_data/chatId/... nicht), Code-Nodes (String-Literale im jsCode, Kommentare
#       gestrippt), Set-Nodes (Zuweisungs-Werte). Bei n8n-Ausdruecken ('=...') zaehlen der Text ausserhalb {{ }} und die
#       JS-String-Literale darin. Ort = "<workflow> / <node>".
#   (b) packages/*/db/migrations/R__*.sql: String-Literale im Code-Anteil (Kommentare quote-aware gestrippt). Ort = Pfad.
#   (c) Telegram-Texte des Installers provisioning/*.sh + provisioning/lib/**/*.sh. Senken: Formular-Argumente
#       text=/caption= (-F, --form, --form-string, --data-urlencode, --data, -d) und jedes Argument eines Helfers, das
#       in so eine Senke fliesst (notify_owner_telegram, _ur_send, ...; per Fixpunkt ueber "$1"/local x="$1" erkannt).
#       Der Wert darf nur aus Expansionen bestehen: Variablen (in derselben Funktion bzw. dateiglobal aufgeloest) und
#       Befehlsersetzungen wie $(pkg_text core <key>) / $(backup_text <suffix> ...); printf/echo in einer Ersetzung
#       zaehlen mit ihrem Text. Treffer = jedes feste Wort aus >= 3 Buchstaben, auch englisch (ein Telegram-Text hat die
#       Sprache des Empfaengers). log/warn/ok/die gehen nur ins Installer-Log und sind keine Senke. Nicht erkannt:
#       JSON-Bodies (--data '{"text":...}') und Texte, die ueber eine Datei/Umgebung in einen anderen Prozess wandern.
#       Ort = Pfad.
# Treffer (a)/(b) = Literal mit deutscher Signatur (Umlaut/ß oder ein typisches deutsches Funktionswort) und mindestens
# einem Wort aus >= 3 Buchstaben; Katalog-Keys, englische Gruende/Codes und Identifier fallen so heraus.
# Selbst-Asserts laufen vor jedem Scan; stirbt die Erkennung still, bricht der Lint.
# Aufruf: .\scripts\ui_literal_lint.ps1 [-Verbose] [-Baseline]
#         .\scripts\ui_literal_lint.ps1 -ShellFile a.sh,b.sh   (nur Scan (c) dieser Dateien, ohne Allowlist; Test-Einstieg)
# -Baseline: druckt die gefundenen (where,literal,count) als JSON-Geruest (reason:'TODO').
# Exit-Code = Anzahl Fehler (-ShellFile: Anzahl Treffer). Kein LLM, kein Netz, kein Substrat.
param([switch]$Baseline, [switch]$Verbose, [string[]]$ShellFile)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Erkennung -------------------------------------------------------------------------------------------------
$germanRx = [regex]::new('[äöüÄÖÜß]|(?<![A-Za-z])(und|oder|nicht|bitte|danke|hallo|willkommen|der|das|den|dem|des|ein|eine|einen|einem|ist|sind|wird|wurde|werden|kein|keine|mit|für|von|zum|zur|auf|du|dein|deine|deinen|dich|dir|ich|mich|mir|wir|euer|eure|jetzt|noch|schon|gerade|heute|hier|auch|bei|bereich|nutzer|haushalt|erledigt|gespeichert|verworfen|aktiv)(?![A-Za-z])', 'IgnoreCase')
function Test-GermanText([string]$S) {
    if ($S -notmatch '[A-Za-zÄÖÜäöüß]{3,}') { return $false }
    if ($S -match '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$') { return $false }   # Katalog-Key
    return $germanRx.IsMatch($S)
}
# JS-/SQL-String-Literale ('...' | "..." | `...`) einer Code-Zeile (Kommentar-Anteil vorher gestrippt).
$jsLitRx  = [regex]"'((?:[^'\\]|\\.)*)'|""((?:[^""\\]|\\.)*)""|``((?:[^``\\]|\\.)*)``"
$sqlLitRx = [regex]"'((?:[^']|'')*)'"
function Get-JsLiterals([string]$Code) {
    foreach ($m in $jsLitRx.Matches($Code)) {
        foreach ($g in 1, 2, 3) { if ($m.Groups[$g].Success) { $m.Groups[$g].Value } }
    }
}
# JS-Zeilenkommentar quote-aware strippen.
function Get-JsCode([string]$Line) {
    $q = $null
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($q) { if ($c -eq '\') { $i++; continue }; if ($c -eq $q) { $q = $null }; continue }
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '`') { $q = $c; continue }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { return $Line.Substring(0, $i) }
    }
    return $Line
}
function Get-SqlCode([string]$Line) {
    $inS = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inS) { if ($c -eq "'") { $inS = $false }; continue }
        if ($c -eq "'") { $inS = $true; continue }
        if ($c -eq '-' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '-') { return $Line.Substring(0, $i) }
    }
    return $Line
}
# Texte eines n8n-Parameter-Werts: Ausdruck ('=...') -> Text ausserhalb {{ }} + JS-Literale darin; sonst der Wert.
function Get-ParamTexts([string]$V) {
    if (-not $V.StartsWith('=')) { return , $V }
    $body = $V.Substring(1)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($seg in [regex]::Split($body, '\{\{[\s\S]*?\}\}')) { if ($seg.Trim()) { $out.Add($seg) } }
    foreach ($m in [regex]::Matches($body, '\{\{([\s\S]*?)\}\}')) {
        foreach ($l in (Get-JsLiterals $m.Groups[1].Value)) { $out.Add($l) }
    }
    return $out.ToArray()
}
# Alle String-Blaetter eines Parameter-Baums (ohne nicht-textuelle Schluessel).
$skipKeys = @('chatId', 'callback_data', 'url', 'resource', 'operation', 'chatApproval', 'approverIds', 'parse_mode',
              'parseMode', 'draftId', 'queryId', 'callbackQueryId', 'fileId', 'messageId', 'replyToMessageId', 'webhookId')
function Get-StringLeaves($Obj, [string]$Key = '') {
    if ($null -eq $Obj) { return }
    if ($skipKeys -contains $Key) { return }
    if ($Obj -is [string]) { $Obj; return }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) { foreach ($x in $Obj) { Get-StringLeaves $x $Key }; return }
    if ($Obj -is [psobject]) { foreach ($p in $Obj.PSObject.Properties) { Get-StringLeaves $p.Value $p.Name } }
}

# --- Scan (c): bash ---------------------------------------------------------------------------------------------
# Index des schliessenden Zeichens ab $i (hinter dem Oeffner); kind sq|dq|bt|paren|brace|top. Unterminiert -> Laenge.
function Find-ShEnd([string]$s, [int]$i, [string]$kind) {
    $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ($kind -eq 'sq') { if ($c -eq "'") { return $i }; $i++; continue }
        if ($kind -eq 'bt') { if ($c -eq '\') { $i += 2; continue }; if ($c -eq '`') { return $i }; $i++; continue }
        if ($c -eq '\') { $i += 2; continue }
        if ($kind -eq 'dq' -and $c -eq '"') { return $i }
        if ($kind -eq 'paren' -and $c -eq ')') { return $i }
        if ($kind -eq 'brace' -and $c -eq '}') { return $i }
        if ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '(') { $i = (Find-ShEnd $s ($i + 2) 'paren') + 1; continue }
        if ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '{') { $i = (Find-ShEnd $s ($i + 2) 'brace') + 1; continue }
        if ($c -eq '`') { $i = (Find-ShEnd $s ($i + 1) 'bt') + 1; continue }
        if ($kind -ne 'dq') {
            if ($c -eq "'") { $i = (Find-ShEnd $s ($i + 1) 'sq') + 1; continue }
            if ($c -eq '"') { $i = (Find-ShEnd $s ($i + 1) 'dq') + 1; continue }
            if ($kind -eq 'paren' -and $c -eq '(') { $i = (Find-ShEnd $s ($i + 1) 'paren') + 1; continue }
        }
        $i++
    }
    return $n
}
function Get-ShSub([string]$s, [int]$from, [int]$end) { if ($end -gt $s.Length) { $end = $s.Length }; if ($end -le $from) { return '' }; return $s.Substring($from, $end - $from) }
$shSep = @(';', '|', '&', '||', '&&', ';;', '(', ')', '<', '>')
# Woerter einer Befehlszeile (Quotes/Ersetzungen bleiben im Wort); Trenner als eigene Woerter; ein '#' am Wortanfang beendet.
function Split-ShWords([string]$s) {
    $words = New-Object System.Collections.Generic.List[string]
    $i = 0; $n = $s.Length; $start = -1
    while ($i -lt $n) {
        $c = $s[$i]
        if ($start -lt 0) {
            if ($c -match '\s') { $i++; continue }
            if ($c -eq '#') { break }
            if ('; | & ( ) < >'.Split(' ') -contains [string]$c) {
                $j = $i + 1; while ($j -lt $n -and $s[$j] -eq $c -and $j - $i -lt 2) { $j++ }
                $words.Add($s.Substring($i, $j - $i)); $i = $j; continue
            }
            $start = $i
        }
        if ($c -match '\s' -or ('; | & ( ) < >'.Split(' ') -contains [string]$c)) { $words.Add($s.Substring($start, $i - $start)); $start = -1; continue }
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq "'") { $i = (Find-ShEnd $s ($i + 1) 'sq') + 1; continue }
        if ($c -eq '"') { $i = (Find-ShEnd $s ($i + 1) 'dq') + 1; continue }
        if ($c -eq '`') { $i = (Find-ShEnd $s ($i + 1) 'bt') + 1; continue }
        if ($c -eq '$' -and $i + 1 -lt $n -and ($s[$i + 1] -eq '(' -or $s[$i + 1] -eq '{')) {
            $i = (Find-ShEnd $s ($i + 2) $(if ($s[$i + 1] -eq '(') { 'paren' } else { 'brace' })) + 1; continue
        }
        $i++
    }
    if ($start -ge 0) { $words.Add($s.Substring($start, [Math]::Min($i, $n) - $start)) }
    return , $words.ToArray()
}
# Wortlisten einer Zeile: die Zeile selbst und jede (verschachtelte) Befehlsersetzung darin -- eine Senke steht oft in
# resp="$(_up_api ... --data-urlencode "text=$t")".
function Get-ShWordLists([string]$s) {
    $lists = New-Object System.Collections.Generic.List[object]
    $lists.Add((Split-ShWords $s))
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -eq "'") { $i = (Find-ShEnd $s ($i + 1) 'sq') + 1; continue }
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '(') {
            $e = Find-ShEnd $s ($i + 2) 'paren'
            foreach ($l in (Get-ShWordLists (Get-ShSub $s ($i + 2) $e))) { $lists.Add($l) }
            $i = $e + 1; continue
        }
        $i++
    }
    return , $lists.ToArray()
}
function New-ShAcc { @{ sb = New-Object System.Text.StringBuilder; vars = New-Object System.Collections.Generic.List[string]; pos = New-Object System.Collections.Generic.List[int] } }
# Expansion ab $i ('$' oder '`') in den Akkumulator; liefert den Index dahinter.
function Add-ShExpansion([string]$s, [int]$i, $acc) {
    $n = $s.Length
    if ($s[$i] -eq '`') { $e = Find-ShEnd $s ($i + 1) 'bt'; Add-ShSubst (Get-ShSub $s ($i + 1) $e) $acc; return $e + 1 }
    if ($i + 1 -ge $n) { [void]$acc.sb.Append('$'); return $i + 1 }
    $d = $s[$i + 1]
    if ($d -eq '(') { $e = Find-ShEnd $s ($i + 2) 'paren'; Add-ShSubst (Get-ShSub $s ($i + 2) $e) $acc; return $e + 1 }
    if ($d -eq '{') {
        $e = Find-ShEnd $s ($i + 2) 'brace'; $inner = Get-ShSub $s ($i + 2) $e
        [void]$acc.sb.Append('{}')
        $m = [regex]::Match($inner, '^[#!]?([A-Za-z_]\w*|\d+)')
        if ($m.Success) { if ($m.Groups[1].Value -match '^\d+$') { $acc.pos.Add([int]$m.Groups[1].Value) } else { $acc.vars.Add($m.Groups[1].Value) } }
        $dm = [regex]::Match($inner, '^[A-Za-z_]\w*:?[-=+](.*)$')
        if ($dm.Success) { Add-ShWord $dm.Groups[1].Value $acc }   # Default-Text ${x:-Text} zaehlt mit
        return $e + 1
    }
    $m = [regex]::Match($s.Substring($i + 1), '^([A-Za-z_]\w*|\d|[@*#?$!-])')
    if ($m.Success) {
        [void]$acc.sb.Append('{}')
        $v = $m.Groups[1].Value
        if ($v -match '^\d$') { $acc.pos.Add([int]$v) } elseif ($v -match '^[A-Za-z_]') { $acc.vars.Add($v) }
        return $i + 1 + $v.Length
    }
    [void]$acc.sb.Append('$'); return $i + 1
}
# Befehlsersetzung: printf/echo liefern ihren Text, jeder andere Befehl (pkg_text, backup_text, jq, date ...) einen Wert.
function Add-ShSubst([string]$inner, $acc) {
    $w = Split-ShWords $inner
    $k = 0; while ($k -lt $w.Count -and $w[$k] -match '^[A-Za-z_]\w*=') { $k++ }
    if ($k -ge $w.Count -or ($w[$k] -ne 'printf' -and $w[$k] -ne 'echo')) { [void]$acc.sb.Append('{}'); return }
    for ($j = $k + 1; $j -lt $w.Count; $j++) {
        if ($shSep -contains $w[$j]) { break }
        if ($w[$j] -eq '-v') { $j++; continue }
        if ($w[$j] -match '^-[neE]+$') { continue }
        [void]$acc.sb.Append(' '); Add-ShWord $w[$j] $acc
    }
}
function Add-ShDq([string]$s, $acc) {
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -eq '\' -and $i + 1 -lt $n) { [void]$acc.sb.Append($s[$i + 1]); $i += 2; continue }
        if ($c -eq '$' -or $c -eq '`') { $i = Add-ShExpansion $s $i $acc; continue }
        [void]$acc.sb.Append($c); $i++
    }
}
function Add-ShWord([string]$w, $acc) {
    $i = 0; $n = $w.Length
    while ($i -lt $n) {
        $c = $w[$i]
        if ($c -eq "'") { $e = Find-ShEnd $w ($i + 1) 'sq'; [void]$acc.sb.Append((Get-ShSub $w ($i + 1) $e)); $i = $e + 1; continue }
        if ($c -eq '"') { $e = Find-ShEnd $w ($i + 1) 'dq'; Add-ShDq (Get-ShSub $w ($i + 1) $e) $acc; $i = $e + 1; continue }
        if ($c -eq '$' -and $i + 1 -lt $n -and $w[$i + 1] -eq "'") {
            $e = Find-ShEnd $w ($i + 2) 'sq'; [void]$acc.sb.Append(((Get-ShSub $w ($i + 2) $e) -replace '\\[ntr]', ' ')); $i = $e + 1; continue
        }
        if ($c -eq '$' -or $c -eq '`') { $i = Add-ShExpansion $w $i $acc; continue }
        if ($c -eq '\' -and $i + 1 -lt $n) { [void]$acc.sb.Append($w[$i + 1]); $i += 2; continue }
        [void]$acc.sb.Append($c); $i++
    }
}
# Fester Text eines Werts: Expansionen als {}, printf-Platzhalter ebenso; leer = kein festes Wort.
function Get-ShFixedText($acc) {
    $t = ($acc.sb.ToString() -replace '%[-0-9.]*[sdif]', '{}' -replace '\s+', ' ').Trim()
    if (($t -replace '\{\}', ' ') -match '[A-Za-zÄÖÜäöüß]{3,}') { return $t }
    return ''
}

# Datei-Modell: Zeilen ohne Here-Doc-Inhalt und Voll-Kommentare, je Zeile die umgebende Funktion.
function New-ShFile([string]$Rel, [string[]]$Lines) {
    $func = New-Object string[] $Lines.Count
    $skip = New-Object bool[] $Lines.Count
    $cur = ''; $hd = $null
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        $l = $Lines[$k]
        if ($hd) { $skip[$k] = $true; if ($l.Trim() -eq $hd) { $hd = $null }; continue }
        if ($l -match '^\s*#') { $skip[$k] = $true; $func[$k] = $cur; continue }
        $fm = [regex]::Match($l, '^\s*(?:function\s+)?([A-Za-z_][\w:.-]*)\s*\(\)\s*(\{|$)')
        if ($fm.Success) { $cur = $fm.Groups[1].Value }
        $func[$k] = $cur
        if ($l -match '^\}') { $cur = '' }
        $hm = [regex]::Match($l, '(?<![<$])<<-?\s*[''"]?([A-Za-z_]\w*)[''"]?')
        if ($hm.Success -and ($l.Substring(0, $hm.Index).Split("'").Count % 2) -eq 1) { $hd = $hm.Groups[1].Value }
    }
    return @{ rel = $Rel; lines = $Lines; func = $func; skip = $skip }
}
# Logische Zeile ab $k: haengt Folgezeilen an, solange ein Backslash endet oder ein Quote/eine Ersetzung offen ist.
function Test-ShOpen([string]$s) {
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -eq '#' -and ($i -eq 0 -or $s[$i - 1] -match '\s')) { return $false }
        if ($c -eq '\') { $i += 2; continue }
        $kind = $null; $len = 1
        if ($c -eq "'") { $kind = 'sq' } elseif ($c -eq '"') { $kind = 'dq' } elseif ($c -eq '`') { $kind = 'bt' }
        elseif ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '(') { $kind = 'paren'; $len = 2 }
        elseif ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '{') { $kind = 'brace'; $len = 2 }
        if ($kind) { $e = Find-ShEnd $s ($i + $len) $kind; if ($e -ge $n) { return $true }; $i = $e + 1; continue }
        $i++
    }
    return $false
}
function Get-ShLogical($F, [int]$k) {
    $s = $F.lines[$k]; $j = $k
    while ($j + 1 -lt $F.lines.Count -and $j - $k -lt 40) {
        if ($s -match '\\$') { $s = $s.Substring(0, $s.Length - 1) + ' ' + $F.lines[$j + 1]; $j++; continue }
        if (-not (Test-ShOpen $s)) { break }
        $s = $s + "`n" + $F.lines[$j + 1]; $j++
    }
    return $s
}
# Scan (c) ueber ein Datei-Set: Fixpunkt ueber die Helfer-Senken, dann Funde (rel, line, literal).
function Invoke-ShScan($Files) {
    $helpers = @{}   # name -> @(arg-index, ...)
    $formRx = '(?:^|\s)(?:-F|--form|--form-string|--data-urlencode|--data|-d)\s+[''"]?(?:text|caption)='
    for ($round = 0; $round -lt 8; $round++) {
        $script:shFind = @{}; $before = ($helpers.Keys | Sort-Object | ForEach-Object { "$_=$($helpers[$_] -join ',')" }) -join ';'
        $names = @($helpers.Keys)
        $helperRx = if ($names.Count) { '(?<![\w$-])(' + (($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![\w-])' } else { $null }
        foreach ($F in $Files) {
            for ($k = 0; $k -lt $F.lines.Count; $k++) {
                if ($F.skip[$k]) { continue }
                $l = $F.lines[$k]
                if (-not ($l -match '(?:text|caption)=' -or ($helperRx -and $l -match $helperRx))) { continue }
                $code = Get-ShLogical $F $k
                foreach ($w in (Get-ShWordLists $code)) {
                    for ($j = 0; $j -lt $w.Count; $j++) {
                        $vals = @()
                        if ($j + 1 -lt $w.Count -and ('-F', '--form', '--form-string', '--data-urlencode', '--data', '-d') -contains $w[$j]) {
                            $m = [regex]::Match($w[$j + 1], '^(["'']?)(text|caption)=')
                            if ($m.Success) { $vals += ($m.Groups[1].Value + $w[$j + 1].Substring($m.Length)) }
                        }
                        if ($helpers.ContainsKey($w[$j]) -and -not ($j -gt 0 -and ('-F', '-f', 'command', 'type', 'unset') -contains $w[$j - 1])) {
                            foreach ($ix in $helpers[$w[$j]]) {
                                if ($j + $ix -lt $w.Count -and -not ($shSep -contains $w[$j + $ix])) { $vals += $w[$j + $ix] }
                            }
                        }
                        foreach ($v in $vals) { Test-ShValue $F $k $v $helpers @{} }
                    }
                }
            }
        }
        $after = ($helpers.Keys | Sort-Object | ForEach-Object { "$_=$($helpers[$_] -join ',')" }) -join ';'
        if ($after -eq $before) { break }
    }
    return @{ helpers = $helpers; found = $script:shFind }
}
# Wert einer Senke pruefen: fester Text -> Fund; Variablen aufloesen; "$N" macht die Funktion zur Helfer-Senke.
function Test-ShValue($F, [int]$k, [string]$Raw, $helpers, $seen) {
    $acc = New-ShAcc
    Add-ShWord $Raw $acc
    $t = Get-ShFixedText $acc
    if ($t) { $script:shFind["$($F.rel)|$($k + 1)|$t"] = 1 }
    $fn = $F.func[$k]
    foreach ($p in $acc.pos) {
        if (-not $fn -or $p -lt 1) { continue }
        if (-not $helpers.ContainsKey($fn)) { $helpers[$fn] = @() }
        if ($helpers[$fn] -notcontains $p) { $helpers[$fn] = @($helpers[$fn]) + $p }
    }
    foreach ($v in $acc.vars) {
        $key = "$fn|$v"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = 1
        $rx = '(?<![\w$])' + [regex]::Escape($v) + '\+?='
        $hits = @()
        foreach ($scope in @($fn, '')) {
            for ($a = 0; $a -lt $F.lines.Count; $a++) {
                if ($F.skip[$a] -or $F.func[$a] -ne $scope -or $F.lines[$a] -notmatch $rx) { continue }
                foreach ($wd in (Split-ShWords (Get-ShLogical $F $a))) {
                    $am = [regex]::Match($wd, '^' + [regex]::Escape($v) + '\+?=')
                    if ($am.Success) { $hits += , @($a, $wd.Substring($am.Length)) }
                }
            }
            if ($hits.Count -or -not $scope) { break }
        }
        foreach ($h in $hits) { Test-ShValue $F $h[0] $h[1] $helpers $seen }
    }
}
function Read-ShFiles([string[]]$Paths) {
    foreach ($p in $Paths) {
        $full = (Resolve-Path $p).Path
        $rel = if ($full.StartsWith($RepoRoot.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) { $full.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/') } else { $full }
        New-ShFile $rel ([System.IO.File]::ReadAllLines($full, $u8))
    }
}

# --- Selbst-Asserts ---------------------------------------------------------------------------------------------
$selfCases = @(
    @{ k = 'param'; c = '=Hallo {{ $json.x }}, willkommen!';                         want = @('Hallo ', ', willkommen!') }
    @{ k = 'param'; c = "={{ 'Nicht verfügbar' }}";                                   want = @('Nicht verfügbar') }
    @{ k = 'param'; c = "={{ ((`$json.t || {})['core.orch.x'] || 'core.orch.x') }}";   want = @() }
    @{ k = 'param'; c = 'Danke! Deine Anfrage wurde gesendet.';                        want = @('Danke! Deine Anfrage wurde gesendet.') }
    @{ k = 'js';    c = "const a = 'Bitte prüfen'; // und noch ein Kommentar";          want = @('Bitte prüfen') }
    @{ k = 'js';    c = "const b = 'unknown action'; const u = 'https://x.y/z';";      want = @() }
    @{ k = 'sql';   c = "RETURN jsonb_build_object('toast', 'Absender nicht erkannt'); -- der Kommentar"; want = @('Absender nicht erkannt') }
    @{ k = 'sql';   c = "RAISE EXCEPTION 'unknown est action %', v;";                   want = @() }
)
foreach ($sc in $selfCases) {
    $cands = switch ($sc.k) {
        'param' { @(Get-ParamTexts $sc.c) }
        'js'    { @(Get-JsLiterals (Get-JsCode $sc.c)) }
        'sql'   { @($sqlLitRx.Matches((Get-SqlCode $sc.c)) | ForEach-Object { $_.Groups[1].Value }) }
    }
    $got = @($cands | Where-Object { Test-GermanText $_ })
    if (($got -join '|') -ne (@($sc.want) -join '|')) {
        Fail "Selbst-Assert ($($sc.k)): '$($sc.c)' -> erwartet [$(@($sc.want) -join ', ')], gefunden [$($got -join ', ')] -- Erkennung defekt"
    }
}
$shSelf = New-ShFile 'selftest.sh' @(
    'notify_owner_telegram() {'
    '  tg_api_curl "$t" sendMessage --data-urlencode "chat_id=${c}" --data-urlencode "text=$1" >/dev/null'
    '}'
    'send_a() {'
    '  local cap; cap="Backup vom $(date -u +%F)"'
    '  curl -F "chat_id=${c}" -F "caption=${cap}"'
    '}'
    'send_b() { notify_owner_telegram "$(pkg_text core backup.notify.ok)"; }'
    'send_c() { notify_owner_telegram "Rückweg fertig: ${rel}"; }'
    'send_d() { log "Off-Site-Kopie gesendet"; warn "kein Token"; }'
    'send_e() { local t; t="$(backup_text notify.x days "$d")"; t="${t} $(backup_text notify.y)"; notify_owner_telegram "$t"; }'
    'send_f() { r="$(_up_api "$k" sendMessage --data-urlencode "text=$(printf ''Hallo %s'' "$n")")"; }'
)
$shSelfRes = Invoke-ShScan @($shSelf)
$shGot = (@($shSelfRes.found.Keys) | Sort-Object) -join ' # '
$shWant = 'selftest.sh|12|Hallo {} {} # selftest.sh|5|Backup vom {} # selftest.sh|9|Rückweg fertig: {}'
if ($shGot -ne $shWant) { Fail "Selbst-Assert (sh): erwartet [$shWant], gefunden [$shGot] -- Erkennung defekt" }
if (-not $shSelfRes.helpers.ContainsKey('notify_owner_telegram')) { Fail 'Selbst-Assert (sh): Helfer-Senke notify_owner_telegram nicht erkannt' }
if ($fails -gt 0) { Write-Host "ui_literal_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

if ($ShellFile) {
    $res = Invoke-ShScan @(Read-ShFiles $ShellFile)
    foreach ($k in (@($res.found.Keys) | Sort-Object)) { $p = $k -split '\|', 3; Write-Host "  $($p[0]):$($p[1]): $($p[2])" }
    exit $res.found.Count
}

# --- Scan -------------------------------------------------------------------------------------------------------
$found = @{}   # "where|literal" -> count
function Add-Found([string]$Where, [string]$Val) {
    $k = "$Where|$Val"
    if ($script:found.ContainsKey($k)) { $script:found[$k]++ } else { $script:found[$k] = 1 }
}
$wfCount = 0
foreach ($wfDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object { Join-Path $_.FullName 'workflows' } | Where-Object { Test-Path $_ })) {
    foreach ($file in (Get-ChildItem $wfDir -Filter '*.json')) {
        $wf = [System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json
        if (-not $wf.nodes) { continue }
        $wfCount++
        foreach ($n in $wf.nodes) {
            $where = "$($wf.name) / $($n.name)"
            switch ([string]$n.type) {
                'n8n-nodes-base.telegram' {
                    foreach ($v in (Get-StringLeaves $n.parameters)) { foreach ($t in (Get-ParamTexts $v)) { if (Test-GermanText $t) { Add-Found $where $t } } }
                }
                'n8n-nodes-base.code' {
                    foreach ($line in ([string]$n.parameters.jsCode -split "`n")) {
                        foreach ($t in (Get-JsLiterals (Get-JsCode $line))) { if (Test-GermanText $t) { Add-Found $where $t } }
                    }
                }
                'n8n-nodes-base.set' {
                    foreach ($a in @($n.parameters.assignments.assignments)) {
                        if ($null -eq $a -or -not ($a.value -is [string])) { continue }
                        foreach ($t in (Get-ParamTexts $a.value)) { if (Test-GermanText $t) { Add-Found $where $t } }
                    }
                }
            }
        }
    }
}
if ($wfCount -eq 0) { Fail 'Scope-Selbst-Assert: keine gebauten Workflows gefunden -- Scan tot (Pfad?)' }
$sqlCount = 0
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\db\migrations\R__*.sql'))) {
    $sqlCount++
    $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, $u8)) {
        foreach ($m in $sqlLitRx.Matches((Get-SqlCode $line))) {
            $t = $m.Groups[1].Value -replace "''", "'"
            if (Test-GermanText $t) { Add-Found $rel $t }
        }
    }
}
if ($sqlCount -eq 0) { Fail 'Scope-Selbst-Assert: keine R__-Dateien gefunden -- Scan tot (Pfad?)' }
$prov = Join-Path $RepoRoot 'provisioning'
$shPaths = @(Get-ChildItem $prov -Filter '*.sh' -File) + @(Get-ChildItem (Join-Path $prov 'lib') -Filter '*.sh' -File -Recurse)
$shRes = Invoke-ShScan @(Read-ShFiles ($shPaths | ForEach-Object { $_.FullName }))
$shLines = @{}   # "where|literal" -> Zeilen
foreach ($k in (@($shRes.found.Keys) | Sort-Object)) {
    $p = $k -split '\|', 3
    Add-Found $p[0] $p[2]
    $shLines["$($p[0])|$($p[2])"] = @($shLines["$($p[0])|$($p[2])"]) + $p[1] | Where-Object { $_ }
}
if (-not $shRes.helpers.ContainsKey('notify_owner_telegram')) { Fail 'Scope-Selbst-Assert: Helfer-Senke notify_owner_telegram in provisioning/lib nicht erkannt -- Scan (c) tot (Pfad/Umbenennung?)' }

# --- Baseline-Modus ---------------------------------------------------------------------------------------------
if ($Baseline) {
    $entries = foreach ($k in ($found.Keys | Sort-Object)) {
        $p = $k -split '\|', 2
        [ordered]@{ where = $p[0]; literal = $p[1]; count = $found[$k]; reason = 'TODO' }
    }
    [ordered]@{ _comment = 'Baseline -- Begruendung je Eintrag (model:<warum> | admin:<warum> | data:<warum>)'; allow = @($entries) } | ConvertTo-Json -Depth 6
    exit 0
}

# --- Allowlist laden + Abgleich ---------------------------------------------------------------------------------
$alPath = Join-Path $RepoRoot 'scripts\build\ui_literal_allowlist.json'
if (-not (Test-Path $alPath)) { Fail "Allowlist fehlt: $alPath (mit -Baseline erzeugen + Begruendungen eintragen)"; Write-Host "ui_literal_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
$allow = @{}
foreach ($e in $al.allow) {
    $key = "$([string]$e.where)|$([string]$e.literal)"
    $r = [string]$e.reason
    if ($r -match '^debt:\S' -and ([string]$e.where).StartsWith('provisioning/')) { }
    elseif ($r -notmatch '^(model|admin|data):\S') { Fail "allowlist: Eintrag '$key' -- reason muss 'model:<warum>', 'admin:<warum>' oder 'data:<warum>' sein (ist '$r'); ein Nutzertext gehoert in den Katalog (seit Phase C keine phase-c-Ausnahme mehr)" }
    if ($allow.ContainsKey($key)) { Fail "allowlist: doppelter Eintrag '$key'"; continue }
    $allow[$key] = [int]$e.count
}
foreach ($key in ($found.Keys | Sort-Object)) {
    $p = $key -split '\|', 2
    if (-not $allow.ContainsKey($key)) {
        if ($shLines.ContainsKey($key)) {
            Fail "NEUER fester Telegram-Text in $($p[0]) Zeile $($shLines[$key] -join ','): '$($p[1])' -- Text aus dem Katalog holen: `$(pkg_text <pkg> <key>) bzw. `$(backup_text <suffix>) (§3.11)"
        } else {
            Fail "NEUER fest deutscher Text in $($p[0]): '$($p[1])' ($($found[$key])x) -- Katalog-Key nutzen (§3.11) ODER mit Begruendung in scripts/build/ui_literal_allowlist.json"
        }
    } elseif ($allow[$key] -ne $found[$key]) {
        Fail "Anzahl '$($p[1])' in $($p[0]): gefunden $($found[$key]), Allowlist $($allow[$key]) -- Allowlist-count anpassen (bei Umstellung schrumpfen)"
    }
}
foreach ($key in ($allow.Keys | Sort-Object)) {
    if (-not $found.ContainsKey($key)) {
        $p = $key -split '\|', 2
        Fail "allowlist-ORPHAN in $($p[0]): '$($p[1])' -- nicht (mehr) vorhanden, Eintrag entfernen (Ratchet schrumpft)"
    }
}
if ($Verbose) { foreach ($k in ($found.Keys | Sort-Object)) { Write-Host "  $k = $($found[$k])" -ForegroundColor DarkGray } }
if ($fails -eq 0) { Write-Host "ui_literal_lint: OK ($($found.Count) allowlistete Stelle(n) aus $wfCount Workflows + $sqlCount R__-Dateien, kein neuer deutscher Text)" -ForegroundColor Green }
else { Write-Host "ui_literal_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
