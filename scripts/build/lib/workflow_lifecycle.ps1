#Requires -Version 5.1
# Workflow-Lifecycle (shared) — die EINE Stelle fuer Workflow-ID-Verwaltung + File-Save.
# Dot-gesourct von scripts/build/build.ps1. KEINE API-Calls hier (Deploy = bootstrap_test_n8n.ps1 / provision.sh).
#
# Prinzip (IaC-Muster): die getrackten packages/<pkg>/workflows/<id>-<name>.json sind der STATE (Name->ID).
# Generatoren backen die ID ein, die hier per Name aus dem State aufgeloest wird. Neuer Workflow ->
# keine Datei -> Save schreibt eine id-lose Datei; der Autor vergibt selbst eine n8n-konforme ID im
# Dateinamen (<id>-<name>.json), import:workflow (deploy_workflows.sh) erhaelt sie. So sind
# "vergessene IDs" strukturell unmoeglich (eine zentrale Aufloesung, ein Deploy-Pfad).
#
# KEINE hardcodierten echten IDs: JEDE Workflow-Cross-Referenz (Gate, Tools, Crons UND die Infra-Subs
# errorWorkflow/load_config/load_context) wird in build.ps1 per Name aus dem State aufgeloest
# (Get-WorkflowIdByName). Credential-Refs nutzen lesbare Deploy-Platzhalter (__CRED_*__, analog
# __OWNER_CHAT_ID__), die inject_credentials/deploy_workflows gegen die frisch geminteten ids tauscht.

# Sanitizer: aus n8n-Workflow-Name den Dateinamens-Stamm. Punkte behalten (n8n-Namens-Konsistenz);
# nur Pfad-/Space-/Doppelpunkt-Zeichen -> '_', der Rest auf [\w.-] reduziert.
function Get-SafeName {
    param([Parameter(Mandatory)][string]$Name)
    return (($Name -replace '[\\/ :]', '_') -replace '[^\w.-]', '')
}

# --- Paket-bewusste Workflow-Verzeichnisse -----------------------------------------------------------
# Workflows liegen paket-getrennt: jedes Paket besitzt seine Workflows unter packages/<pkg>/workflows/.
# Get-WorkflowDirs liefert die komplette SUCH-Liste (Cross-Ref-Aufloesung spannt Pakete),
# Get-WorkflowHomeDir die EINE ZIEL-Dir je Workflow (aus dem Paket-Scope des Namens).
function Get-WorkflowDirs {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dirs = @()
    foreach ($p in (Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
        $w = Join-Path $p.FullName 'workflows'
        if (Test-Path $w) { $dirs += $w }
    }
    return @($dirs)
}

# Manifest-getriebene Paket->Home-Dir-Map (Phase 0 WS-0c #7, gecacht je Build): jedes Paket besitzt seine
# Workflows unter packages/<pkg>/workflows (Default); ein Paket koennte via optionalem manifest-Feld
# "workflows_dir" abweichen (aktuell nutzt keins es). Loest die fruehere agent.finance*/agent.career*-
# Sonderfall-Kette ab -> ein neues Paket dockt ohne Code-Edit an (Owner-Direktive: generisch statt Prefix-Hardcode).
$script:WorkflowHomeMap = $null
function Get-WorkflowHomeMap {
    param([Parameter(Mandatory)][string]$RepoRoot)
    if ($null -ne $script:WorkflowHomeMap) { return $script:WorkflowHomeMap }
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $map = [ordered]@{}
    foreach ($mf in (Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
        $mfPath = Join-Path $mf.FullName 'manifest.json'
        if (-not (Test-Path $mfPath)) { continue }
        $m = [System.IO.File]::ReadAllText($mfPath, $u8) | ConvertFrom-Json
        $pkg = [string]$m.name
        if ([string]::IsNullOrEmpty($pkg)) { continue }
        $homeDir = if ($m.workflows_dir) { [string]$m.workflows_dir } else { "packages/$pkg/workflows" }  # lint-ignore: dynamischer Pfad ($pkg-Variable, kein Datei-Literal)
        $map[$pkg] = ($homeDir -replace '/', '\')
    }
    $script:WorkflowHomeMap = $map
    return $map
}

# Paket, dem ein Workflow-NAME gehoert (die EINE Namens->Paket-Regel; Get-WorkflowHomeDir + die Besitz-Pruefung
# der approval_matrix nutzen sie).
function Get-WorkflowPackage {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$RepoRoot)
    $map = Get-WorkflowHomeMap $RepoRoot
    # Nicht-Core-Pakete beanspruchen den Scope-Prefix agent.<pkg> (segment-genau: exakt / '.'- / '_'-Suffix ->
    # ein Paketname, der Prefix eines anderen ist, kollidiert nicht), z. B. agent.<pkg>(.tool_*|_advisor).
    foreach ($pkg in $map.Keys) {
        if ($pkg -eq 'core') { continue }
        if ($Name -eq "agent.$pkg" -or $Name -like "agent.$pkg.*" -or $Name -like "agent.${pkg}_*") { return $pkg }
    }
    # Core = der HOST: die bare Agent-Infra (agent.orchestrator/monitor/guide/advisor/tool_*) + core.* — keine
    # eigene agent.<pkg>-Domaene. Faengt alles, was kein Nicht-Core-Paket beansprucht.
    if ($Name -like 'core.*' -or $Name -like 'agent.*') { return 'core' }
    throw "Get-WorkflowHomeDir: '$Name' matcht kein Paket-Scope (kein 'agent.<pkg>'-Prefix aus den Manifesten, kein core.*/agent.*-Host-Name) — Workflow-Name-Typo oder fehlendes Manifest?"
}

function Get-WorkflowHomeDir {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$RepoRoot)
    $map = Get-WorkflowHomeMap $RepoRoot
    $pkg = Get-WorkflowPackage $Name $RepoRoot
    # Home aus dem Manifest (Default packages/<pkg>/workflows); Core-Fallback, falls kein core-Manifest existiert.
    $homeRel = if ($map.Contains($pkg)) { $map[$pkg] } else { "packages\$pkg\workflows" }
    return (Join-Path $RepoRoot $homeRel)
}

# Loest die n8n-ID eines Workflows per Name aus dem State (<id>-<safe>.json) auf — ueber EINE oder
# MEHRERE Workflow-Dirs (Cross-Refs spannen alle packages/<pkg>/workflows).
# Dateiname = '<id>-<safe>.json'; die n8n-ID ist ein Nanoid OHNE '-', also ist alles vor dem ERSTEN
# '-' die ID und der Rest muss EXAKT '<safe>.json' sein (so trifft 'agent.finance' NICHT die
# 'agent.finance.tool_*'-Dateien). Liefert '' wenn (noch) keine Datei existiert; wirft bei >1 Treffer.
function Get-WorkflowIdByName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$WorkflowsDir   # ein Pfad ODER eine Liste (Single-String wird auto-gewrappt)
    )
    $want = (Get-SafeName $Name) + '.json'
    $hits = @()
    foreach ($dir in $WorkflowsDir) {
        foreach ($f in (Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $dash = $f.Name.IndexOf('-')
            if ($dash -lt 1) { continue }                   # 'name.json' ohne ID-Praefix -> ignorieren
            if ($f.Name.Substring($dash + 1) -eq $want) { $hits += $f.Name.Substring(0, $dash) }
        }
    }
    $hits = @($hits | Select-Object -Unique)
    if ($hits.Count -gt 1) { throw "Get-WorkflowIdByName: mehrere IDs fuer '$Name' gefunden: $($hits -join ', ')" }
    if ($hits.Count -eq 1) { return $hits[0] }
    return ''
}

# Pflicht-Aufloesung einer Cross-Referenz (Phase D, die EINE Stelle des frueher ~9x kopierten
# "Get-WorkflowIdByName + throw"-Musters). Fehlt die Datei im State -> throw mit Aufrufer + Hinweis.
# -Soft = Warnung + '' (fuer Ziele, die beim Erst-Build legitim noch fehlen: 2-Pass-Bootstrap — der
# Aufrufer-Node bleibt unaufgeloest, bis das Ziel gebaut + seine ID im Dateinamen vergeben ist).
# Liest $WorkflowsDir per Dynamic Scope (build.ps1 setzt es vor jedem Aufruf).
function Get-RequiredWorkflowId {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Caller,
        [switch]$Soft
    )
    $id = Get-WorkflowIdByName $Name $WorkflowsDir
    if ($id) { return $id }
    $msg = "${Caller}: '$Name' nicht im State (packages/*/workflows) -- Platzhalter packages/<pkg>/workflows/<16-Zeichen-nanoid>-$Name.json mit {} anlegen, dann neu bauen (packages/CLAUDE.md, Neues Tool)."
    if ($Soft) { Write-Warning "$msg Der Aufruf-Node bleibt bis dahin unaufgeloest (2-Pass-Bootstrap)."; return '' }
    throw $msg
}

# Service-Alias-Resolver (D9, build-time): dereferenziert eine logische Core-Dienst-Referenz
# 'core:<name>' zum PHYSISCHEN n8n-Workflow-NAMEN ueber die Provider-Map aus
# packages/core/manifest.json (provides.services). Die name->id-Aufloesung bleibt die EINE
# bestehende Mechanik Get-WorkflowIdByName (Datei-State) — der Resolver fuegt nur die
# Alias-Indirektion davor ein (kein DB-Zugriff: build.ps1 generiert nur Dateien).
# WICHTIG: gibt den NAMEN zurueck, NICHT die id — der Aufrufer braucht den Namen auch fuer
# cachedResultName; ein "gib die id zurueck"-Refactor wuerde toolWorkflow-Nodes brechen.
function Resolve-CoreServiceAlias {
    param(
        [Parameter(Mandatory)][string]$Ref,        # 'core:<name>'
        [Parameter(Mandatory)]$ServiceMap          # Hashtable alias -> workflow-name (aus dem Core-Manifest)
    )
    if ($Ref -notmatch '^core:([a-z][a-z0-9_]*)$') {
        throw "Resolve-CoreServiceAlias: ungueltige Referenz '$Ref' (erwartet 'core:<name>')."
    }
    $alias = $Matches[1]
    if (-not $ServiceMap.ContainsKey($alias)) {
        throw "Resolve-CoreServiceAlias: unbekannter Core-Dienst '$alias' (nicht in core/manifest.json provides.services)."
    }
    return $ServiceMap[$alias]
}

# --- Stabile Knoten-IDs (deterministischer Build) -----------------------------------------------------
# Die Builder vergeben per New-Id nur PLATZHALTER; Save-WorkflowFile ersetzt jede Knoten-id, jede vorhandene
# webhookId und jede GUID-foermige innere id (IF-Bedingungen, Set-Zuweisungen) durch eine UUID-v5 aus
# Workflow-Name + Knoten-Name (+ JSON-Pfad). Ein unveraenderter Workflow ergibt so eine byte-identische Datei
# (kein Rausch-Diff, kein Rebase-Konflikt, keine Neu-Registrierung beim Deploy). n8n 2.44.4 verlangt nur:
# Knoten-ids eindeutig JE Workflow (<= 36 Zeichen), webhookIds eindeutig INSTANZWEIT (Telegram-Trigger-Pfad
# <webhookId>/webhook, PK webhook_entity) -> der Workflow-Name steckt im Hash (Namen sind repo-weit eindeutig).
# Sendandwait/HITL loest ueber Execution + node.id auf, nie ueber die webhookId.
$script:GuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# RFC 4122 UUID-v5 (SHA-1). Namespace-Bytes aus dem Hex-String (NICHT [guid]::ToByteArray(): das vertauscht die
# ersten drei Felder); Ausgabe direkt aus den Hash-Bytes in Netzwerk-Reihenfolge.
function ConvertTo-StableUuid {
    param([Parameter(Mandatory)][string]$Name, [string]$Namespace = $script:StableIdNamespace)
    $hex = $Namespace -replace '-', ''
    $buf = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt 16; $i++) { $buf.Add([Convert]::ToByte($hex.Substring($i * 2, 2), 16)) }
    $buf.AddRange([System.Text.Encoding]::UTF8.GetBytes($Name))
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $h = $sha.ComputeHash($buf.ToArray()) } finally { $sha.Dispose() }
    $h[6] = [byte](($h[6] -band 0x0F) -bor 0x50)   # Version 5
    $h[8] = [byte](($h[8] -band 0x3F) -bor 0x80)   # Variante RFC 4122
    $s = ([System.BitConverter]::ToString($h, 0, 16) -replace '-', '').ToLowerInvariant()
    return '{0}-{1}-{2}-{3}-{4}' -f $s.Substring(0, 8), $s.Substring(8, 4), $s.Substring(12, 4), $s.Substring(16, 4), $s.Substring(20, 12)
}
# Selbsttest mit dem RFC-Vektor (DNS-Namespace) — eine kaputte Implementierung bricht den Build, bevor sie IDs aendert.
$script:UuidNsDns = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'
if ((ConvertTo-StableUuid 'www.example.com' $script:UuidNsDns) -ne '2ed6657d-e927-568b-95e1-2665a8aea6a2') {
    throw 'ConvertTo-StableUuid: RFC-4122-Testvektor verfehlt (UUID-v5-Implementierung defekt).'
}
# Projekt-Namespace, selbst abgeleitet statt Magie-Literal. NIE aendern: jede Aenderung erneuert alle IDs.
$script:StableIdNamespace = ConvertTo-StableUuid 'n8n-life-agents/workflow-node-ids' $script:UuidNsDns

# Normalisiert einen Teilbaum fuer die Serialisierung: ungeordnete Dictionaries -> ordinal sortiertes [ordered]
# (Ausgabe unabhaengig von .NET-String-Hashes: 32/64 Bit, pwsh), PSCustomObject -> [ordered] (Reihenfolge bleibt),
# Arrays elementweise. Mit -IdPrefix wird jeder Key 'id', dessen Wert ein New-Id-Platzhalter ist, zu
# UUID-v5(Prefix + Pfad); eine feste GUID bleibt stehen und faellt danach in Find-StrayGuid auf.
function ConvertTo-StableJsonValue {
    param($Value, [string]$Path, [string]$IdPrefix, $Issued)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) { return $Value }
    $isDict = $Value -is [System.Collections.IDictionary]
    if ($isDict -or $Value -is [System.Management.Automation.PSCustomObject]) {
        if ($isDict) {
            $keys = [string[]]@($Value.Keys)
            if ($Value -isnot [System.Collections.Specialized.OrderedDictionary]) { [Array]::Sort($keys, [System.StringComparer]::Ordinal) }
        } else { $keys = [string[]]@($Value.PSObject.Properties | ForEach-Object { $_.Name }) }
        $o = [ordered]@{}
        foreach ($k in $keys) {
            # Zuweisung IN den Zweigen: `$v = if (…) { … }` rollte ein Ein-Element-Array auf (Pipeline) -> Array weg.
            if ($isDict) { $v = $Value[$k] } else { $v = $Value.$k }
            $p = if ($Path) { "$Path.$k" } else { $k }
            if ($IdPrefix -and $k -eq 'id' -and $v -is [string] -and $script:NewIdIssued.Contains($v)) {
                $nv = ConvertTo-StableUuid "$IdPrefix`n$p"
                [void]$Issued.Add($nv); $o[$k] = $nv
            } else { $o[$k] = ConvertTo-StableJsonValue $v $p $IdPrefix $Issued }
        }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        $i = 0
        foreach ($e in $Value) { $list.Add((ConvertTo-StableJsonValue $e "$Path[$i]" $IdPrefix $Issued)); $i++ }
        return , ($list.ToArray())   # Unary-Komma: Array nicht aufrollen (Einzel-Element bleibt Array)
    }
    return $Value
}

# Erster GUID-foermiger String-Wert, den Set-StableNodeIds NICHT gesetzt hat (Pfad), sonst ''. credentials-Teilbaeume
# tragen Platzhalter und werden uebersprungen.
function Find-StrayGuid {
    param($Value, [string]$Path, $Issued)
    if ($Value -is [string]) { if ($Value -match $script:GuidRx -and -not $Issued.Contains($Value)) { return $Path }; return '' }
    if ($null -eq $Value -or $Value -is [System.ValueType]) { return '' }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            if ($k -eq 'credentials') { continue }
            $hit = Find-StrayGuid $Value[$k] "$Path.$k" $Issued; if ($hit) { return $hit }
        }
        return ''
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($e in $Value) { $hit = Find-StrayGuid $e "$Path[$i]" $Issued; if ($hit) { return $hit }; $i++ }
    }
    return ''
}

# Liefert das normalisierte Workflow-Objekt (neues [ordered]) mit stabilen IDs. Wirft bei doppelten Knoten-Namen
# (n8n-Pflicht; sonst kollidierten die IDs) und bei jedem verbliebenen GUID-foermigen Wert (neue Zufallsquelle,
# z. B. ein [guid]::NewGuid() im Builder) -> der Determinismus ist durchgesetzt, nicht nur Konvention.
function Set-StableNodeIds {
    param([Parameter(Mandatory)]$Workflow, [Parameter(Mandatory)][string]$Name)
    $issued = New-Object 'System.Collections.Generic.HashSet[string]'
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = [ordered]@{}
    foreach ($k in @($Workflow.Keys)) {
        if ($k -ne 'nodes') { $out[$k] = ConvertTo-StableJsonValue $Workflow[$k] $k '' $issued; continue }
        $nodes = New-Object System.Collections.Generic.List[object]
        foreach ($n in @($Workflow[$k])) {
            $nn = if ($n -is [System.Collections.IDictionary]) { $n['name'] } else { $n.name }
            if ([string]::IsNullOrEmpty([string]$nn)) { throw "Set-StableNodeIds: '$Name' hat einen Knoten ohne Namen." }
            if (-not $seen.Add([string]$nn)) { throw "Set-StableNodeIds: '$Name' hat zwei Knoten namens '$nn' (n8n verlangt eindeutige Namen)." }
            $prefix = "$Name`n$nn"
            $node = ConvertTo-StableJsonValue $n '' $prefix $issued
            foreach ($pin in @('id', 'webhookId')) {
                if (-not $node.Contains($pin)) { continue }
                if ($n -is [System.Collections.IDictionary]) { $orig = $n[$pin] } else { $orig = $n.$pin }
                if (-not ($orig -is [string] -and $script:NewIdIssued.Contains($orig))) {
                    throw "Set-StableNodeIds: '$Name' / Knoten '$nn' setzt $pin fest ('$orig') — (New-Id) verwenden, Save-WorkflowFile macht ihn stabil."
                }
            }
            $node['id'] = ConvertTo-StableUuid $prefix
            [void]$issued.Add($node['id'])
            if ($node.Contains('webhookId')) {
                $node['webhookId'] = ConvertTo-StableUuid "$prefix`nwebhookId"
                [void]$issued.Add($node['webhookId'])
            }
            $nodes.Add($node)
        }
        $out[$k] = $nodes.ToArray()
    }
    $stray = Find-StrayGuid $out '' $issued
    if ($stray) { throw "Set-StableNodeIds: '$Name' traegt einen zufaelligen GUID-Wert bei '$stray' — Builder auf New-Id umstellen (Save-WorkflowFile macht ihn stabil) oder den Wert entfernen." }
    return $out
}

# Schreibt das Workflow-Objekt (OHNE id-Feld) als getrackte Datei. ID via Get-WorkflowIdByName:
#   - bekannt   -> '<id>-<safe>.json' mit eingebackener id (import:workflow erhaelt sie); verwaiste bare-Datei weg.
#   - unbekannt -> bare '<safe>.json'; der Autor vergibt selbst eine n8n-konforme id im Dateinamen.
# OwnerChatId-Redaction (-> __OWNER_CHAT_ID__); die echte chat_id re-injiziert deploy_workflows.sh beim Deploy.
# Liefert ein Status-Objekt (Name/Id/File/IsNew) fuer den Orchestrator-Report.
function Save-WorkflowFile {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkflowsDir,
        [string]$OwnerChatId = ''
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $safe = Get-SafeName $Name
    $id   = Get-WorkflowIdByName $Name $WorkflowsDir

    # Netz gegen still leere Credentials (Phase D): jeder Credential-Eintrag jedes Nodes ist ein Deskriptor mit
    # Platzhalter-id __CRED_…__ (ein Tippfehler im Cred-Variablennamen ergaebe sonst still $null -> kaputter Import).
    foreach ($n in @($Workflow.nodes)) {
        $cr = if ($n -is [System.Collections.IDictionary]) { $n['credentials'] } else { $n.credentials }
        if ($null -eq $cr) { continue }
        $pairs = New-Object System.Collections.Generic.List[object]   # List statt @(): ein Einzel-Paar wuerde @() sonst aufrollen
        if ($cr -is [System.Collections.IDictionary]) { foreach ($k in @($cr.Keys)) { $pairs.Add([pscustomobject]@{ Key = $k; Value = $cr[$k] }) } }
        else { foreach ($pp in $cr.PSObject.Properties) { $pairs.Add([pscustomobject]@{ Key = $pp.Name; Value = $pp.Value }) } }
        foreach ($kv in $pairs) {
            $v   = $kv.Value
            $cid = if ($v -is [System.Collections.IDictionary]) { [string]$v['id'] } elseif ($null -ne $v) { [string]$v.id } else { '' }
            if ($cid -notmatch '^__CRED_.+__$') {
                $nn = if ($n -is [System.Collections.IDictionary]) { $n['name'] } else { $n.name }
                throw "Save-WorkflowFile: '$Name' / Node '$nn' / Credential '$($kv.Key)' ohne gueltige Platzhalter-id ('$cid') — Cred-Variable leer oder vertippt?"
            }
        }
    }

    # Build-Zeit-Metadaten ('_*'-Keys, z. B. '_manifest' der Capability-Discovery) werden NIE
    # serialisiert — sie leben nur im Speicher fuer den Generator/Lint.
    if ($id) {
        $out = [ordered]@{ id = $id }
        foreach ($k in $Workflow.Keys) { if ($k -like '_*') { continue }; $out[$k] = $Workflow[$k] }
        $file = Join-Path $WorkflowsDir "$id-$safe.json"
        $bare = Join-Path $WorkflowsDir "$safe.json"
        if (Test-Path $bare) { Remove-Item $bare -Force }   # verwaiste id-lose Datei aufraeumen
    } else {
        $out  = [ordered]@{}
        foreach ($k in $Workflow.Keys) { if ($k -like '_*') { continue }; $out[$k] = $Workflow[$k] }
        $file = Join-Path $WorkflowsDir "$safe.json"
    }

    $out  = Set-StableNodeIds $out $Name
    # LF wie im Index (.gitattributes *.json eol=lf): sonst meldet git nach jedem Build jede Datei als geaendert.
    $json = ($out | ConvertTo-Json -Depth 30) -replace "`r`n", "`n"
    if ($OwnerChatId) {
        $json = $json -replace ('"' + [regex]::Escape($OwnerChatId) + '"'), '"__OWNER_CHAT_ID__"'
    }
    # Nur bei echter Aenderung schreiben: unveraenderte Dateien behalten ihr Aenderungsdatum (kein OneDrive-Sync).
    $same = (Test-Path $file) -and ([System.IO.File]::ReadAllText($file, $utf8) -ceq $json)
    if (-not $same) { [System.IO.File]::WriteAllText($file, $json, $utf8) }

    return [pscustomobject]@{ Name = $Name; Id = $id; File = $file; IsNew = [string]::IsNullOrEmpty($id) }
}
