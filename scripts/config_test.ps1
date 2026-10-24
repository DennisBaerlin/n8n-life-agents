#Requires -Version 5.1
# Config-Smoke (A4c). Kein LLM, kein DB-Write -- prueft die paket-besessenen Config-Bloecke
# (packages/*/manifest.json .config) deterministisch, bevor ein kaputter Standardwert ausgeliefert wird.
#   (1) Selbsttest: der Cron-Pruefer hier und core.fn_config_cron_valid (DB) pruefen DIESELBE Fallliste
#       tests/util/util_cron_cases.sql (JSON zwischen den $cases$-Markern) -> beide koennen nicht auseinanderlaufen.
#   (2) Je Eintrag: type ∈ string|integer|number|boolean|cron, minimum/maximum nur bei integer/number (Zahlen,
#       minimum <= maximum), managed_by ∈ owner|system, und der Standardwert passt zu Typ + Grenzen (dieselben Regeln
#       wie core.fn_config_value_valid). Kategorie-Pflicht: schedule -> cron, cron_enable -> boolean.
#   (3) Zeitplan-Platzhalter: jeder `__CFG_SCHEDULE_<KEY>__` in packages/<pkg>/workflows/*.json hat seine Zeile
#       .config.schedule.<key> im Manifest DESSELBEN Pakets, und jede schedule-Zeile wird von einem Workflow genutzt
#       (der Installer setzt den Wert beim Einspielen ein, provisioning/lib/deploy_workflows.sh).
#   (4) Modelle wirken zur Laufzeit (Festwert-Phase 2) — statisch ueber die gebauten Workflows + den Bau-Code:
#       (a) jeder Bezug $('<Knoten>').item|first().json.model.<key> zeigt auf einen Config-Knoten DESSELBEN Workflows;
#           bei 'Load model config' (New-ModelConfigNode) muss der Knoten genau diesen Key laden und dem Bezug im
#           Ablauf vorausgehen (bei Umschaltern: der Kette, an der der Umschalter haengt); die geladenen (Paket, Key)
#           stehen als .config.model.<key> im Manifest des Pakets. Agenten lesen ueber core.sub_load_config ('Load
#           Config'/'Load core.config', alle Zeilen) -> dort genuegt: der Key ist irgendeine Manifest-Modell-Zeile.
#       (b) jede Manifest-Modell-Zeile wird von mindestens einem Workflow gelesen (jede Zeile in config list wirkt);
#       (c) kein Anthropic-HTTP-Knoten traegt ein Modell-Literal (das Modell kommt aus dem Config-Knoten);
#       (d) die Bau-Zeit-Helfer Get-PackageConfig/Get-AnthropicModel kommen im Bau-Code nicht mehr vor.
#   (5) Modell-Register packages/core/seed/ai_models.json (Quelle des Selector-Baus): mode chat|embedding, chat <=>
#       selector_index, Chat nur Anthropic, Chat-Nummern lueckenlos 1..n, und jeder Manifest-model.*-Standard ist dort
#       ein Chat-Modell. mode/Nummer spiegeln die DB (ai_models_mode_*_check, core.fn_model_value_eligible — die
#       sieht die JSON erst beim Seed); "Chat nur Anthropic" und "Nummern lueckenlos" sind reine Bau-Regeln
#       (New-LmChatNode baut nur Claude, der Selector verdrahtet Eingang selector_index-1).
#
# Usage:  .\scripts\config_test.ps1 [-Verbose]
# Exit-Code = Anzahl fehlgeschlagener Checks. Laufende Modell-Werte (category='model') prueft die DB
# (Fremdschluessel core:V024, trg_config_check_model_value, test_config_model_selector.sql).
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

$script:failed = 0
function Fail([string]$Msg) { Write-Host "  [FAIL] $Msg" -ForegroundColor Red; $script:failed++ }
function Pass([string]$Msg) { if ($Verbose) { Write-Host "  [PASS] $Msg" -ForegroundColor Green } }

# Validiert EIN Cron-Feld gegen seinen Wertebereich [min,max]. Erlaubt: *, n, a-b, a-b/s, */s, n/s, Listen mit ','.
function Test-CronField([string]$Field, [int]$Min, [int]$Max) {
    if ($Field -eq '') { return $false }
    foreach ($part in ($Field -split ',')) {
        $p = $part
        if ($p -cmatch '^(.+)/([0-9]{1,2})\z') { $p = $Matches[1]; if ([int]$Matches[2] -lt 1) { return $false } }
        if ($p -eq '*') { continue }
        if ($p -cmatch '^([0-9]{1,2})-([0-9]{1,2})\z') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -lt $Min -or $b -gt $Max -or $a -gt $b) { return $false }
            continue
        }
        if ($p -cmatch '^[0-9]{1,2}\z') {
            $n = [int]$p
            if ($n -lt $Min -or $n -gt $Max) { return $false }
            continue
        }
        return $false   # unbekanntes Token (Name, leeres Listen-Element, Vorzeichen …)
    }
    return $true
}

# Validiert eine ganze Cron-Expression: 5 Felder oder 6 mit FESTER Sekunde vorn (n8n-Form). Spiegel von
# core.fn_config_cron_valid (packages/core/db/core.config_init.sql).
function Test-CronExpression([string]$Expr) {
    if ($null -eq $Expr) { return $false }
    $fields = @(($Expr.Trim(" `t")) -split '[ \t]+')
    if ($fields.Count -eq 6) {
        if ($fields[0] -cnotmatch '^[0-9]{1,2}\z' -or [int]$fields[0] -gt 59) { return $false }
        $fields = $fields[1..5]
    }
    if ($fields.Count -ne 5) { return $false }
    $bounds = @(@(0,59),@(0,23),@(1,31),@(1,12),@(0,7))
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-CronField $fields[$i] $bounds[$i][0] $bounds[$i][1])) { return $false }
    }
    return $true
}

# Spiegel von core.fn_config_value_valid.
function Test-ConfigValue([string]$Type, [string]$Value, $Min, $Max) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    switch -CaseSensitive ($Type) {
        'string'  { return $true }
        'boolean' { return ($Value -ceq 'true' -or $Value -ceq 'false') }
        'cron'    { return (Test-CronExpression $Value) }
        'integer' { if ($Value -cnotmatch '^-?[0-9]{1,10}\z' -or [long]$Value -lt -2147483648 -or [long]$Value -gt 2147483647) { return $false } }   # int4 wie core.fn_config_value_valid
        'number'  { if ($Value -cnotmatch '^-?[0-9]{1,15}([.][0-9]{1,15})?\z') { return $false } }
        default   { return $false }
    }
    $v = [decimal]::Parse($Value, $inv)
    if ($null -ne $Min -and $v -lt [decimal]$Min) { return $false }
    if ($null -ne $Max -and $v -gt [decimal]$Max) { return $false }
    return $true
}

Write-Host ""
Write-Host "Config-Smoke (packages/*/manifest.json .config)"
Write-Host ("-" * 60)

# ---------- (1) Selbsttest gegen die gemeinsame Fallliste ----------
$casesPath = Join-Path $RepoRoot 'tests\util\util_cron_cases.sql'
$casesSql  = [System.IO.File]::ReadAllText($casesPath, $Utf8NoBom)
$m = [regex]::Match($casesSql, 'lifeagents\.cron_cases'',\s*\$cases\$(.*?)\$cases\$', 'Singleline')
if (-not $m.Success) { Fail "Fallliste tests/util/util_cron_cases.sql: keine `$cases`$-Marker gefunden" }
else {
    $cases = ConvertFrom-Json -InputObject $m.Groups[1].Value   # -InputObject: PS 5.1 liefert sonst das Array als EIN Element
    if ($cases.Count -lt 10) { Fail "Fallliste: nur $($cases.Count) Faelle gelesen" }
    foreach ($c in $cases) {
        $got = Test-CronExpression ([string]$c.cron)
        if ($got -ne [bool]$c.valid) { Fail "Cron-Fall '$($c.cron)': erwartet valid=$($c.valid), Pruefer sagt $got" }
        else { Pass "Cron-Fall '$($c.cron)' = $got" }
    }
    Write-Host "  (1) Cron-Pruefer gegen $($cases.Count) gemeinsame Faelle geprueft"
}

# ---------- (2) Manifest-Eintraege ----------
$validTypes  = @('string','integer','number','boolean','cron')
$requireType = @{ schedule = 'cron'; cron_enable = 'boolean' }
$schedules   = @{}   # "<pkg>|<key>" -> $true
$modelDefaults = @{} # "<pkg>: model.<key>" -> Standard-model_key (Check 5)
$modelKeys   = @{}   # "<pkg>|<key>" -> $true (Check 4)
$entries = 0
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory)) {
    $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
    if (-not (Test-Path $mfPath)) { continue }
    $mf = [System.IO.File]::ReadAllText($mfPath, $Utf8NoBom) | ConvertFrom-Json
    if ($null -eq $mf.config) { continue }
    foreach ($cat in $mf.config.PSObject.Properties) {
        if ($cat.Name -eq '_comment') { continue }
        foreach ($k in $cat.Value.PSObject.Properties) {
            if ($k.Name -eq '_comment') { continue }
            $entries++
            $e = $k.Value; $where = "$($mf.name): $($cat.Name).$($k.Name)"
            $names = @($e.PSObject.Properties.Name)
            $type = if ($names -contains 'type') { [string]$e.type } else { 'string' }
            $min  = if ($names -contains 'minimum') { $e.minimum } else { $null }
            $max  = if ($names -contains 'maximum') { $e.maximum } else { $null }
            if ($validTypes -cnotcontains $type) { Fail "$where.type '$type' unbekannt (erlaubt: $($validTypes -join '|'))"; continue }
            if ($requireType.ContainsKey($cat.Name) -and $type -cne $requireType[$cat.Name]) {
                Fail "$where muss type '$($requireType[$cat.Name])' tragen (Kategorie $($cat.Name)), hat '$type'"
            }
            if (($null -ne $min -or $null -ne $max) -and $type -cnotin @('integer','number')) { Fail "$where`: minimum/maximum nur bei integer/number" }
            foreach ($b in @($min, $max)) {
                if ($null -ne $b -and -not ($b -is [int] -or $b -is [long] -or $b -is [double] -or $b -is [decimal])) { Fail "$where`: minimum/maximum muss eine JSON-Zahl sein ('$b')" }
            }
            if ($null -ne $min -and $null -ne $max -and [decimal]$min -gt [decimal]$max) { Fail "$where`: minimum > maximum" }
            if ($names -contains 'managed_by' -and @('owner','system') -cnotcontains [string]$e.managed_by) { Fail "$where.managed_by '$($e.managed_by)' (erlaubt: owner|system)" }
            $val = [string]$e.value
            if (-not (Test-ConfigValue $type $val $min $max)) { Fail "$where`: Standardwert '$val' passt nicht zu type '$type'$(if ($null -ne $min) { " min $min" })$(if ($null -ne $max) { " max $max" })" }
            else { Pass "$where = '$val' ($type)" }
            if ($cat.Name -eq 'schedule') { $schedules["$($mf.name)|$($k.Name)"] = $true }
            if ($cat.Name -eq 'model') { $modelDefaults[$where] = $val; $modelKeys["$($mf.name)|$($k.Name)"] = $true }
        }
    }
}
Write-Host "  (2) $entries Config-Eintraege geprueft ($($schedules.Count) Zeitplaene)"

# ---------- (3) Zeitplan-Platzhalter <-> schedule-Zeilen ----------
$used = @{}
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory)) {
    $wfDir = Join-Path $pkgDir.FullName 'workflows'
    if (-not (Test-Path $wfDir)) { continue }
    foreach ($wf in (Get-ChildItem $wfDir -Filter '*.json' -File)) {
        $txt = [System.IO.File]::ReadAllText($wf.FullName, $Utf8NoBom)
        foreach ($pm in [regex]::Matches($txt, '__CFG_SCHEDULE_([A-Z0-9_]+)__')) {
            $key = $pm.Groups[1].Value.ToLowerInvariant()
            $id = "$($pkgDir.Name)|$key"
            $used[$id] = $true
            if (-not $schedules.ContainsKey($id)) {
                Fail "$($pkgDir.Name)/workflows/$($wf.Name): Platzhalter $($pm.Value) ohne Zeile .config.schedule.$key im Manifest von '$($pkgDir.Name)'"
            }
        }
    }
}
foreach ($id in $schedules.Keys) {
    if (-not $used.ContainsKey($id)) {
        $p = $id -split '\|'
        Fail "$($p[0]): .config.schedule.$($p[1]) wird von keinem Workflow des Pakets genutzt (kein __CFG_SCHEDULE_$($p[1].ToUpperInvariant())__) — tote Zeile oder Build vergessen?"
    }
}
Write-Host "  (3) $($used.Count) Zeitplan-Platzhalter in den Workflows geprueft"

# ---------- (4) Modelle zur Laufzeit: Bezuege <-> Config-Knoten <-> Manifest ----------
$cfgNode      = 'Load model config'                  # New-ModelConfigNode
$fullCfgNodes = @('Load Config', 'Load core.config')  # core.sub_load_config bzw. Orchestrator: ALLE Config-Zeilen
$refRx = "\`$\('([^']+)'\)\.(?:item|first\(\))\.json\.model\.([a-z][a-z0-9_]*)"
# Modell-Keys sind paket-uebergreifend eindeutig (core.config UNIQUE(category,key)) -> die Lese-Pruefung (b) darf nach
# dem Key-Namen zaehlen; eine Doppel-Deklaration failt hier statt erst beim Seed.
$anyModelKey = @{}
foreach ($id in $modelKeys.Keys) {
    $p = $id -split '\|'
    if ($anyModelKey.ContainsKey($p[1])) { Fail "model.$($p[1]) ist in mehreren Paketen deklariert ($($anyModelKey[$p[1]]), $($p[0])) — core.config verlangt UNIQUE(category,key)" }
    $anyModelKey[$p[1]] = $p[0]
}
$readKeys = @{}; $refCount = 0; $httpCount = 0
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory)) {
    $wfDir = Join-Path $pkgDir.FullName 'workflows'
    if (-not (Test-Path $wfDir)) { continue }
    foreach ($wfFile in (Get-ChildItem $wfDir -Filter '*.json' -File)) {
        $wf = [System.IO.File]::ReadAllText($wfFile.FullName, $Utf8NoBom) | ConvertFrom-Json
        $where = "$($pkgDir.Name)/workflows/$($wfFile.Name)"
        $nodesByName = @{}; foreach ($n in @($wf.nodes)) { $nodesByName[[string]$n.name] = $n }
        # Rueckwaerts-Kanten (main) + Umschalter-Ziel (ai_languageModel) aus den Verbindungen.
        $parents = @{}; $lmTarget = @{}
        if ($null -ne $wf.connections) {
            foreach ($src in $wf.connections.PSObject.Properties) {
                foreach ($typ in $src.Value.PSObject.Properties) {
                    foreach ($branch in @($typ.Value)) { foreach ($edge in @($branch)) {
                        if ($null -eq $edge -or $null -eq $edge.node) { continue }
                        if ($typ.Name -eq 'main') { if (-not $parents.ContainsKey($edge.node)) { $parents[$edge.node] = @() }; $parents[$edge.node] += $src.Name }
                        elseif ($typ.Name -eq 'ai_languageModel') { $lmTarget[$src.Name] = $edge.node }
                    } }
                }
            }
        }
        # Geladene Keys des Config-Knotens (queryReplacement-Liste {pkg,key}) + Manifest-Pruefung.
        $loaded = @{}
        if ($nodesByName.ContainsKey($cfgNode)) {
            $qr = [string]$nodesByName[$cfgNode].parameters.options.queryReplacement
            foreach ($lm in [regex]::Matches($qr, '"pkg":"([a-z0-9_]+)","key":"([a-z0-9_]+)"')) {
                $loaded[$lm.Groups[2].Value] = $true
                if (-not $modelKeys.ContainsKey("$($lm.Groups[1].Value)|$($lm.Groups[2].Value)")) {
                    Fail "${where}: '$cfgNode' laedt model.$($lm.Groups[2].Value) von Paket '$($lm.Groups[1].Value)', das Manifest deklariert die Zeile nicht"
                }
            }
            if ($loaded.Count -eq 0) { Fail "${where}: '$cfgNode' ohne erkennbare {pkg,key}-Liste im queryReplacement" }
        }
        foreach ($n in @($wf.nodes)) {
            $ptxt = ConvertTo-Json -InputObject $n.parameters -Depth 40 -Compress
            $ptxt = $ptxt -replace '\\u0027', "'"
            foreach ($rm in [regex]::Matches($ptxt, $refRx)) {
                $refCount++
                $src = $rm.Groups[1].Value; $key = $rm.Groups[2].Value
                $readKeys[$key] = $true
                if ($src -eq $cfgNode) {
                    if (-not $loaded.ContainsKey($key)) { Fail "${where}: Knoten '$($n.name)' liest model.$key aus '$cfgNode', der Knoten laedt den Key nicht (oder fehlt)" }
                    # Vorgaenger-Pruefung: Bezug am Umschalter -> die Kette, an der er haengt.
                    $anchor = [string]$n.name; $hops = 0
                    while ($lmTarget.ContainsKey($anchor) -and $hops -lt 5) { $anchor = $lmTarget[$anchor]; $hops++ }
                    $seen = @{}; $stack = New-Object System.Collections.Stack; $stack.Push($anchor); $found = $false
                    while ($stack.Count -gt 0) {
                        $cur = $stack.Pop()
                        if ($seen.ContainsKey($cur)) { continue }; $seen[$cur] = $true
                        foreach ($p in @($parents[$cur])) { if ($null -eq $p) { continue }; if ($p -eq $cfgNode) { $found = $true; break }; $stack.Push($p) }
                        if ($found) { break }
                    }
                    if (-not $found) { Fail "${where}: '$cfgNode' liegt nicht im Ablauf vor '$anchor' (Bezug in '$($n.name)')" }
                } elseif ($fullCfgNodes -contains $src) {
                    if (-not $anyModelKey.ContainsKey($key)) { Fail "${where}: Knoten '$($n.name)' liest model.$key — keine Manifest-Modell-Zeile mit diesem Key" }
                } else {
                    Fail "${where}: Knoten '$($n.name)' liest model.$key aus unbekanntem Config-Knoten '$src' (erlaubt: '$cfgNode', $($fullCfgNodes -join ', '))"
                }
            }
            # Claude-HTTP-Knoten = Ziel /v1/messages (seit dem LLM-Gateway lokal 127.0.0.1:8090, nicht mehr
            # api.anthropic.com) — Auswahl ueber den Pfad, damit der Waechter nach einer URL-Aenderung nie still leer laeuft.
            if ($n.type -eq 'n8n-nodes-base.httpRequest' -and [string]$n.parameters.url -like '*/v1/messages*') {
                $httpCount++
                if ([string]$n.parameters.url -like '*api.anthropic.com*') { Fail "${where}: Anthropic-HTTP-Knoten '$($n.name)' umgeht den LLM-Gateway (url direkt auf api.anthropic.com) — New-AnthropicMessagesNode nutzen" }
                $body = ([string]$n.parameters.jsonBody) -replace '\\u0027', "'"
                if ($body -match "model:\s*['""]") { Fail "${where}: Anthropic-HTTP-Knoten '$($n.name)' traegt ein Modell-Literal — Modell per New-AnthropicMessagesNode -ConfigModelKey zur Laufzeit lesen" }
                elseif ($body -notmatch '\.json\.model\.') { Fail "${where}: Anthropic-HTTP-Knoten '$($n.name)' liest kein Modell aus einem Config-Knoten" }
            }
        }
    }
}
foreach ($id in $modelKeys.Keys) {
    $k = ($id -split '\|')[1]
    if (-not $readKeys.ContainsKey($k)) { Fail "$($id -replace '\|', ': model.'): wird von keinem Workflow gelesen — die Zeile in config list wirkt nicht" }
}
$srcFiles = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName -match '[\\/]build[\\/]' })
$srcFiles += @(Get-ChildItem (Join-Path $RepoRoot 'scripts\build') -Recurse -Filter '*.ps1' -File)
foreach ($f in $srcFiles) {
    $i = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, $Utf8NoBom)) {
        $i++
        if ($line -match '\b(Get-PackageConfig|Get-AnthropicModel)\b') {
            Fail "$($f.FullName.Substring($RepoRoot.Length + 1)):${i}: $($Matches[1]) backte ein Modell beim Bauen ein — entfernt seit Festwert-Phase 2 (New-ModelConfigNode + Laufzeit-Bezug)"
        }
    }
}
if ($httpCount -eq 0) { Fail "(4) kein Anthropic-HTTP-Knoten (url */v1/messages) gefunden — der Modell-Literal-Waechter liefe still leer (Selektor pruefen)" }
Write-Host "  (4) $refCount Modell-Bezuege + $httpCount Anthropic-HTTP-Knoten geprueft; $($readKeys.Count) Keys gelesen, $($modelKeys.Count) Manifest-Modell-Zeilen"

# ---------- (5) Modell-Register packages/core/seed/ai_models.json ----------
# Der Bau liest die JSON (New-ModelSelectorBundle verdrahtet Eingang selector_index-1 bei numberInputs = Anzahl der
# Chat-Modelle), die DB-CHECKs sehen sie erst beim Seed -> hier dieselben Regeln VOR dem Commit.
$aiPath = Join-Path $RepoRoot 'packages\core\seed\ai_models.json'
# Klammer + ForEach-Object PFLICHT (PS-5.1-Quirk): ConvertFrom-Json reicht das Array sonst als EIN Objekt weiter.
$ai = @(([System.IO.File]::ReadAllText($aiPath, $Utf8NoBom) | ConvertFrom-Json) | ForEach-Object { $_ })
$aiKeys = @{}
foreach ($r in $ai) {
    $mk = [string]$r.model_key
    if ($mk -eq '' -or $aiKeys.ContainsKey($mk)) { Fail "ai_models.json: model_key '$mk' leer oder doppelt"; continue }
    $aiKeys[$mk] = $r
    if (@('chat','embedding') -cnotcontains [string]$r.mode) { Fail "ai_models.json $mk`: mode '$($r.mode)' (erlaubt: chat|embedding)" }
    if (($r.mode -ceq 'chat') -ne ($null -ne $r.selector_index)) { Fail "ai_models.json $mk`: chat braucht selector_index, embedding nie" }
    if ($r.mode -ceq 'chat' -and $r.provider -cne 'Anthropic') { Fail "ai_models.json $mk`: Chat-Modelle laufen nur ueber Anthropic (provider '$($r.provider)')" }
}
$idx = @($ai | Where-Object { $_.mode -ceq 'chat' } | ForEach-Object { [int]$_.selector_index } | Sort-Object)
for ($n = 0; $n -lt $idx.Count; $n++) {
    if ($idx[$n] -ne $n + 1) { Fail "ai_models.json: Chat-selector_index nicht lueckenlos 1..$($idx.Count) ($($idx -join ','))"; break }
}
foreach ($w in $modelDefaults.Keys) {
    $d = $modelDefaults[$w]
    if (-not $aiKeys.ContainsKey($d)) { Fail "$w`: Standard '$d' fehlt in packages/core/seed/ai_models.json" }
    elseif ($aiKeys[$d].mode -cne 'chat') { Fail "$w`: Standard '$d' ist kein Chat-Modell" }
    else { Pass "$w = '$d' (Register)" }
}
Write-Host "  (5) $($ai.Count) Register-Zeilen + $($modelDefaults.Count) Modell-Standards geprueft"

Write-Host ("-" * 60)
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($script:failed) Config-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $script:failed
