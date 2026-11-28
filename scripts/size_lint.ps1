#Requires -Version 5.1
# size_lint.ps1 -- Obergrenzen fuer das, was ein Modell am Stueck lesen muss: Dateigroessen, Werkzeug-Last je Agent und Laenge der
# Sticky-Notes (hartes Gate).
# Den Code lesen KI-Modelle: eine Datei mit 2000 Zeilen kostet bei jedem Oeffnen Kontext, ein Agent mit 60 Werkzeugen bei jedem
# Aufruf. Regeln und Bestand stehen in scripts/build/size_budget.json:
#   rules   je Dateigruppe die Grenzen lines, bytes, line_chars (laengste Zeile). include/exclude sind Regex auf den Repo-Pfad
#           mit '/'; fuer eine Datei gilt die erste passende Regel. Eine neue Datei bleibt unter den Grenzen.
#   files   Bestand ueber einer Grenze: je Datei die Decke jeder ueberschrittenen Groesse.
#   agents  je Agent-Knoten der gebauten Workflows (packages/*/workflows, Schluessel "<workflow> / <knoten>") die Decken tools
#           (Knoten am ai_tool-Eingang), description_chars (Summe der Werkzeug-Beschreibungen) und longest_description.
#   sticky_chars  Grenze fuer den Text einer Sticky-Note; stickies = Bestand darueber ("<workflow> / <sticky>", Decke chars).
# Rot:
#   (1) Datei oder Sticky-Note ueber einer Grenze ohne Decke; Agent ohne Eintrag;
#   (2) Wert ueber seiner Decke (die Datei, der Agent oder die Sticky-Note ist gewachsen);
#   (3) Decke ohne Anlass: Wert unter der Grenze, Datei fehlt oder passt auf keine Regel, Agent oder Sticky-Note fehlt, Eintrag
#       doppelt oder leer;
#   (4) Decke mehr als headroom_pct ueber dem Wert (tools: jede Abweichung) -> Decke senken;
#   (5) Regel ohne id, include oder Grenze.
# Die Decken sinken nur. Eine Decke anzuheben oder einen Eintrag neu anzulegen ist eine Entscheidung des Owners, kein Ausweg aus
# (1) und (2). Gemessen wird nach Umwandlung von CRLF in LF (gleiche Zahlen unter Windows und Linux); bytes = UTF-8 ohne BOM.
# Aufruf: .\scripts\size_lint.ps1 [-Update] [-Root <Baum>]
#   -Update    schreibt size_budget.json neu: Decken, die nicht mehr passen, bekommen den gemessenen Wert, Eintraege ohne Anlass
#              entfallen, fehlende kommen dazu; endet mit 0. Das hebt auch Decken an: nur nach dem Zusammenfuehren von Zweigen
#              (ihr gemeinsamer Stand ist der neue Bestand) oder nach einer Owner-Entscheidung, nie um ein Rot im eigenen Zweig
#              zu beseitigen. Das Ergebnis mit git diff lesen.
#   -Root      prueft einen anderen Baum und nimmt dort alle Dateien statt der git-getrackten (nur scripts/dev/size_lint_test.ps1).
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([switch]$Update, [string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
$Ordinal = [System.StringComparison]::Ordinal
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
# @{} vergleicht Schluessel ohne Gross-/Kleinschreibung; Pfade unterscheiden sie unter Linux.
function New-OrdinalMap { return , (New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)) }

if ($Root) {
    $Root = (Resolve-Path $Root).Path
    $relFiles = @(Get-ChildItem $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') })
} else {
    $Root = (Resolve-Path (git -C $PSScriptRoot rev-parse --show-toplevel)).Path
    $relFiles = @(git -C $Root -c core.quotepath=off ls-files)
}

. (Join-Path $PSScriptRoot 'lib\ordinal.ps1')   # Sort-Ordinal: gleiche Reihenfolge der Meldungen und der Datei auf jedem Rechner
$FileDims  = @('lines', 'bytes', 'line_chars')
$AgentDims = @('tools', 'description_chars', 'longest_description')

function Measure-TextFile([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path, $u8).Replace("`r`n", "`n")
    $lines = 0; $longest = 0
    if ($text.Length -gt 0) {
        $parts = $text.Split([char]10)
        $lines = $parts.Length
        if ($text.EndsWith("`n", $Ordinal)) { $lines-- }
        foreach ($p in $parts) { if ($p.Length -gt $longest) { $longest = $p.Length } }
    }
    return @{ lines = $lines; bytes = $u8.GetByteCount($text); line_chars = $longest }
}

# Aus den gebauten Workflows: Werkzeug-Last je Agent-Knoten (was das Modell bei jedem Aufruf dieses Agenten mitliest) und die
# Textlaenge jeder Sticky-Note.
$loads = New-OrdinalMap
$stickies = New-OrdinalMap
function Read-BuiltWorkflows {
    $pkgRoot = Join-Path $Root 'packages'
    if (-not (Test-Path $pkgRoot)) { return }
    foreach ($pkg in (Get-ChildItem $pkgRoot -Directory)) {
        $wfDir = Join-Path $pkg.FullName 'workflows'
        if (-not (Test-Path $wfDir)) { continue }
        foreach ($f in (Get-ChildItem $wfDir -Filter '*.json' -File)) {
            $wf = [System.IO.File]::ReadAllText($f.FullName, $u8) | ConvertFrom-Json
            $byName = New-OrdinalMap
            foreach ($n in $wf.nodes) {
                $byName[[string]$n.name] = $n
                if ($n.type -ceq 'n8n-nodes-base.stickyNote') { $stickies["$($wf.name) / $($n.name)"] = ("$($n.parameters.content)").Length }
            }
            foreach ($agent in @($wf.nodes | Where-Object { $_.type -ceq '@n8n/n8n-nodes-langchain.agent' })) {
                $tools = 0; $sum = 0; $longest = 0
                foreach ($src in $wf.connections.PSObject.Properties) {
                    $wired = $false
                    foreach ($group in @($src.Value.ai_tool)) { foreach ($c in @($group)) { if ($c -and [string]::Equals([string]$c.node, [string]$agent.name, $Ordinal)) { $wired = $true } } }
                    if (-not $wired) { continue }
                    $tools++
                    $p = $byName[$src.Name].parameters
                    $len = ("$($p.description)").Length + ("$($p.toolDescription)").Length
                    $sum += $len
                    if ($len -gt $longest) { $longest = $len }
                }
                $loads["$($wf.name) / $($agent.name)"] = @{ tools = $tools; description_chars = $sum; longest_description = $longest }
            }
        }
    }
}

$budgetPath = [System.IO.Path]::Combine($Root, 'scripts', 'build', 'size_budget.json')
if (-not (Test-Path -LiteralPath $budgetPath -PathType Leaf)) { Write-Host '  [FAIL] scripts/build/size_budget.json fehlt' -ForegroundColor Red; exit 1 }
$budget = [System.IO.File]::ReadAllText($budgetPath, $u8) | ConvertFrom-Json
$headroom = if ($budget.PSObject.Properties['headroom_pct']) { [int]$budget.headroom_pct } else { 0 }
$stickyLimit = if ($budget.PSObject.Properties['sticky_chars']) { [int]$budget.sticky_chars } else { 0 }   # 0 = Sticky-Notes ohne Grenze
function Get-MaxCap([int]$Value) { return [int][math]::Floor($Value * (100 + $headroom) / 100) }

$rules = @(foreach ($r in @($budget.rules | Where-Object { $_ })) {
    $limits = @{}
    foreach ($d in $FileDims) { if ($r.PSObject.Properties[$d]) { $limits[$d] = [int]$r.$d } }
    if (-not $r.id -or -not $r.include -or $limits.Count -eq 0) { Fail "rules: Regel '$($r.id)' braucht id, include und mindestens eine Grenze (lines|bytes|line_chars)"; continue }
    [pscustomobject]@{ Id = [string]$r.id; Include = [regex][string]$r.include; Exclude = $(if ($r.exclude) { [regex][string]$r.exclude }); Limits = $limits }
})

$measured = New-OrdinalMap
foreach ($rel in $relFiles) {
    $rule = $null
    foreach ($r in $rules) { if ($r.Include.IsMatch($rel) -and -not ($r.Exclude -and $r.Exclude.IsMatch($rel))) { $rule = $r; break } }
    if (-not $rule) { continue }
    $full = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }   # getrackt, im Arbeitsbaum geloescht
    $m = Measure-TextFile $full
    $m.Rule = $rule
    $measured[$rel] = $m
}
Read-BuiltWorkflows
$longStickies = @(Sort-Ordinal @($stickies.Keys | Where-Object { $stickyLimit -gt 0 -and $stickies[$_] -gt $stickyLimit }))

if ($Update) {
    # Eine gueltige Decke bleibt stehen (Wert <= Decke <= Wert + headroom_pct); sonst gilt der gemessene Wert. Eintraege ohne Anlass
    # entfallen. Geschrieben wird die ganze Datei, ein Eintrag je Zeile.
    function Get-KeptCap($Entry, [string]$Dim, [int]$Value, [int]$MaxCap) {
        if ($Entry -and $Entry.PSObject.Properties[$Dim]) { $cap = [int]$Entry.$Dim; if ($Value -le $cap -and $cap -le $MaxCap) { return $cap } }
        return $Value
    }
    # Eigener Schreiber statt ConvertTo-Json: der maskiert in Windows PowerShell 5.1 auch < > & ' und in pwsh 7 nicht; die Datei
    # soll unter beiden gleich aussehen.
    function ConvertTo-JsonValue($Value) {
        if ($Value -is [bool]) { return "$Value".ToLowerInvariant() }
        if ($Value -isnot [string]) { return [string]$Value }
        return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + '"'
    }
    function ConvertTo-JsonRow($Row) {
        return '    { ' + (@($Row.Keys | ForEach-Object { '"' + $_ + '": ' + (ConvertTo-JsonValue $Row[$_]) }) -join ', ') + ' }'
    }
    $old = @{ files = (New-OrdinalMap); agents = (New-OrdinalMap); stickies = (New-OrdinalMap) }
    foreach ($e in @($budget.files | Where-Object { $_ }))    { $old.files[[string]$e.path] = $e }
    foreach ($e in @($budget.agents | Where-Object { $_ }))   { $old.agents[[string]$e.agent] = $e }
    foreach ($e in @($budget.stickies | Where-Object { $_ })) { $old.stickies[[string]$e.sticky] = $e }
    $ruleRows = @(foreach ($r in @($budget.rules | Where-Object { $_ })) { $row = [ordered]@{}; foreach ($p in $r.PSObject.Properties) { $row[$p.Name] = $p.Value }; ConvertTo-JsonRow $row })
    $fileRows = @(foreach ($rel in (Sort-Ordinal @($measured.Keys))) {
        $m = $measured[$rel]; $row = [ordered]@{ path = $rel }
        foreach ($d in $FileDims) { if ($m.Rule.Limits.ContainsKey($d) -and $m[$d] -gt $m.Rule.Limits[$d]) { $row[$d] = Get-KeptCap $old.files[$rel] $d $m[$d] (Get-MaxCap $m[$d]) } }
        if ($row.Count -gt 1) { ConvertTo-JsonRow $row }
    })
    $agentRows = @(foreach ($k in (Sort-Ordinal @($loads.Keys))) {
        $row = [ordered]@{ agent = $k }
        foreach ($d in $AgentDims) { $v = $loads[$k][$d]; $row[$d] = Get-KeptCap $old.agents[$k] $d $v $(if ($d -eq 'tools') { $v } else { Get-MaxCap $v }) }
        ConvertTo-JsonRow $row
    })
    $stickyRows = @(foreach ($k in $longStickies) { ConvertTo-JsonRow ([ordered]@{ sticky = $k; chars = (Get-KeptCap $old.stickies[$k] 'chars' $stickies[$k] (Get-MaxCap $stickies[$k])) }) })
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('{')
    foreach ($p in $budget.PSObject.Properties) {
        if ($p.Name -in 'rules', 'files', 'agents', 'stickies') { continue }
        $out.Add('  "' + $p.Name + '": ' + (ConvertTo-JsonValue $p.Value) + ',')
    }
    $sections = [ordered]@{ rules = $ruleRows; files = $fileRows; agents = $agentRows; stickies = $stickyRows }
    $names = @($sections.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $rows = @($sections[$names[$i]]); $tail = if ($i -lt $names.Count - 1) { ',' } else { '' }
        if ($rows.Count -eq 0) { $out.Add('  "' + $names[$i] + '": []' + $tail); continue }
        $out.Add('  "' + $names[$i] + '": [')
        $out.Add($rows -join ",`n")
        $out.Add('  ]' + $tail)
    }
    $out.Add('}')
    [System.IO.File]::WriteAllText($budgetPath, (($out -join "`n") + "`n"), $u8)
    Write-Host "size_lint -Update: scripts/build/size_budget.json neu geschrieben ($($fileRows.Count) Datei(en), $($agentRows.Count) Agent(en), $($stickyRows.Count) Sticky-Note(s)); Aenderungen mit git diff pruefen." -ForegroundColor Yellow
    exit 0
}

# --- Dateien ---
$entries = New-OrdinalMap
foreach ($e in @($budget.files | Where-Object { $_ })) {
    $path = [string]$e.path
    if ($entries.ContainsKey($path)) { Fail "files: '$path' steht doppelt"; continue }
    $entries[$path] = $e
    if (-not $measured.ContainsKey($path)) { Fail "files: '$path' gibt es nicht oder passt auf keine Regel -- Eintrag streichen"; continue }
    if (@($FileDims | Where-Object { $e.PSObject.Properties[$_] }).Count -eq 0) { Fail "files: '$path' nennt keine Decke -- Eintrag streichen" }
}
foreach ($rel in (Sort-Ordinal @($measured.Keys))) {
    $m = $measured[$rel]; $e = $entries[$rel]; $id = $m.Rule.Id
    foreach ($d in $FileDims) {
        $has = [bool]($e -and $e.PSObject.Properties[$d])
        if (-not $m.Rule.Limits.ContainsKey($d)) {
            if ($has) { Fail "files: '$rel' nennt $d, die Regel '$id' begrenzt $d nicht -- Angabe streichen" }
            continue
        }
        $limit = $m.Rule.Limits[$d]; $val = $m[$d]
        if ($val -le $limit) {
            if ($has) { Fail "files: '$rel' $d = $val liegt unter der Grenze $limit (Regel '$id') -- Angabe streichen" }
            continue
        }
        if (-not $has) { Fail "${rel}: $d = $val ueber der Grenze $limit (Regel '$id') -- Datei teilen oder kuerzen; ein neuer Eintrag in files ist eine Owner-Entscheidung"; continue }
        $cap = [int]$e.$d
        if ($val -gt $cap) { Fail "${rel}: $d = $val ueber der Decke $cap -- die Datei ist gewachsen; kuerzen oder teilen" }
        elseif ($cap -gt (Get-MaxCap $val)) { Fail "files: '$rel' $d-Decke $cap liegt mehr als $headroom % ueber dem Wert $val -- auf hoechstens $(Get-MaxCap $val) senken" }
    }
}

# --- Agenten ---
$agentEntries = New-OrdinalMap
foreach ($e in @($budget.agents | Where-Object { $_ })) {
    $key = [string]$e.agent
    if ($agentEntries.ContainsKey($key)) { Fail "agents: '$key' steht doppelt"; continue }
    $agentEntries[$key] = $e
    if (-not $loads.ContainsKey($key)) { Fail "agents: '$key' gibt es in den gebauten Workflows nicht -- Eintrag streichen" }
}
foreach ($key in (Sort-Ordinal @($loads.Keys))) {
    $load = $loads[$key]; $e = $agentEntries[$key]
    if (-not $e) { Fail "agents: '$key' hat keinen Eintrag (tools $($load.tools), description_chars $($load.description_chars), longest_description $($load.longest_description)) -- eintragen"; continue }
    foreach ($d in $AgentDims) {
        if (-not $e.PSObject.Properties[$d]) { Fail "agents: '$key' nennt $d nicht (heute $($load[$d]))"; continue }
        $cap = [int]$e.$d; $val = $load[$d]
        $maxCap = if ($d -eq 'tools') { $val } else { Get-MaxCap $val }
        if ($val -gt $cap) { Fail "${key}: $d = $val ueber der Decke $cap -- der Agent ist gewachsen; Werkzeuge zusammenlegen oder Beschreibungen kuerzen (Decke anheben = Owner-Entscheidung)" }
        elseif ($cap -gt $maxCap) { Fail "agents: '$key' $d-Decke $cap liegt ueber dem Wert $val -- auf hoechstens $maxCap senken" }
    }
}

# --- Sticky-Notes ---
$stickyEntries = New-OrdinalMap
foreach ($e in @($budget.stickies | Where-Object { $_ })) {
    $key = [string]$e.sticky
    if ($stickyEntries.ContainsKey($key)) { Fail "stickies: '$key' steht doppelt"; continue }
    $stickyEntries[$key] = $e
    if (-not $stickies.ContainsKey($key)) { Fail "stickies: '$key' gibt es in den gebauten Workflows nicht -- Eintrag streichen"; continue }
    $val = $stickies[$key]; $cap = [int]$e.chars
    if ($val -le $stickyLimit) { Fail "stickies: '$key' hat $val Zeichen und liegt unter der Grenze $stickyLimit -- Eintrag streichen" }
    elseif ($val -gt $cap) { Fail "${key}: $val Zeichen ueber der Decke $cap -- die Sticky-Note ist gewachsen; kuerzen oder je Abschnitt eine eigene setzen" }
    elseif ($cap -gt (Get-MaxCap $val)) { Fail "stickies: '$key' Decke $cap liegt mehr als $headroom % ueber dem Wert $val -- auf hoechstens $(Get-MaxCap $val) senken" }
}
foreach ($key in $longStickies) {
    if (-not $stickyEntries.ContainsKey($key)) { Fail "${key}: $($stickies[$key]) Zeichen ueber der Grenze $stickyLimit -- Sticky-Note kuerzen oder je Abschnitt eine eigene setzen" }
}

if ($fails -eq 0) { Write-Host "size_lint: OK ($($measured.Count) Datei(en) unter Regeln, $($entries.Count) mit Decke, $($loads.Count) Agent(en), $($stickies.Count) Sticky-Note(s))" -ForegroundColor Green }
else { Write-Host "size_lint: $fails Fehler." -ForegroundColor Red }
exit $fails
