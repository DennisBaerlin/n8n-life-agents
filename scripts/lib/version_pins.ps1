#Requires -Version 5.1
# Laufzeit-Versionen (n8n, PostgreSQL, Node.js): eine Quelle = die Standardwerte in provisioning/provision.sh.
# Get-RuntimePins <Root>      -> @{N8n; Pg; Node}; wirft, wenn ein Wert nicht lesbar ist.
# Get-VersionPinIssues <Root> -> Meldungen (leer = alles gleich). Aufrufer: doc_lint 11b. Dot-sourcen.
# Zwei Arten von Nennungen:
#   Prosa (Doku: root-*.md, CLAUDE.md, .claude/rules + skills, docs ohne fn_catalog, Site-Quellen): n8n als volle Version 2.x.y,
#   'PostgreSQL <n>', 'Node.js <n>'; dazu alle Abbild-/Installations-Nennungen.
#   Abbild-/Installations-Nennungen (auch scripts/, provisioning/, Workflows, Dockerfiles): n8nio/n8n:<v>, postgres:<n>, :pg<n>,
#   PostgreSQL\<n>\, PostgreSQL.PostgreSQL.<n>, postgresql-<n>, node:<v>. Kommentarzeilen im Code zaehlen nicht.
# compose.yml und master.Dockerfile prueft contract_lint 33 (mit Digest-Pflicht), die Dev-Werkzeug-Pins doc_lint 11.
# Nennung eines frueheren Stands ("geprueft auf <v>") steht mit Anzahl und Grund in scripts/build/version_pin_allowlist.json
# (nur schrumpfen: ein nicht mehr gefundener Eintrag ist rot). Test: scripts/dev/version_pin_lint_test.ps1.

function Get-RuntimePins([string]$Root) {
    $text = [System.IO.File]::ReadAllText((Join-Path $Root 'provisioning/provision.sh'), (New-Object System.Text.UTF8Encoding($false)))
    $pins = @{}
    foreach ($p in @(@('N8n', 'N8N_VERSION', '[0-9]+\.[0-9]+\.[0-9]+'), @('Pg', 'PG_VERSION', '[0-9]+'), @('Node', 'NODE_MAJOR', '[0-9]+'))) {
        $m = [regex]::Match($text, "(?m)^$($p[1])=`"\`$\{$($p[1]):-($($p[2]))\}`"")
        if (-not $m.Success) { throw "provisioning/provision.sh: Standardwert $($p[1]) nicht lesbar -- Quelle der Laufzeit-Versionen umgeschrieben?" }
        $pins[$p[0]] = $m.Groups[1].Value
    }
    return $pins
}

# Muster je Art; Gruppe 1 = die Version, die gleich dem Pin sein muss (node: nur die Hauptversion).
function Get-VersionPatterns {
    $image = @(
        @{ kind = 'N8n';  rx = 'n8nio/n8n:([0-9]+\.[0-9]+\.[0-9]+)' }
        @{ kind = 'Pg';   rx = '\bpostgres:([0-9]{1,2})(?![0-9])' }
        @{ kind = 'Pg';   rx = ':pg([0-9]{2})\b' }
        @{ kind = 'Pg';   rx = 'PostgreSQL(?:\\|/)([0-9]{2})(?:\\|/)' }
        @{ kind = 'Pg';   rx = 'PostgreSQL\.PostgreSQL\.([0-9]{2})' }
        @{ kind = 'Pg';   rx = '\bpostgresql(?:-client)?[-/]([0-9]{2})(?![0-9])' }
        @{ kind = 'Node'; rx = '\bnode:([0-9]{1,2})(?:\.[0-9]+)*' }
    )
    $prose = @(
        @{ kind = 'N8n';  rx = '(?<![\d.v])(2\.[0-9]{1,2}\.[0-9]{1,2})(?![\d.])' }
        @{ kind = 'Pg';   rx = 'PostgreSQL\s+(?:to\s+)?\*{0,2}([0-9]{2})\b' }
        @{ kind = 'Node'; rx = '\bNode(?:\.js)?\s+\*{0,2}([0-9]{2})\b' }
    )
    return @{ image = $image; prose = $prose }
}

function Get-VersionPinFiles([string]$Root) {
    $prose = @(); $code = @()
    function Add-Files($Dir, $Filter, [switch]$Recurse) {
        $p = Join-Path $Root $Dir
        if (-not (Test-Path $p)) { return }
        Get-ChildItem -LiteralPath $p -File -Force -Recurse:$Recurse | Where-Object { $_.Name -match $Filter } |
            ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') }
    }
    $prose += Add-Files '.' '\.md$'
    $prose += Add-Files 'docs' '\.md$' | Where-Object { $_ -ne 'docs/fn_catalog.md' }
    $prose += Add-Files 'docs/reference' '\.md$'
    $prose += Add-Files 'docs/site/content' '\.(md|html)$' -Recurse
    $prose += Add-Files 'docs/site/layouts' '\.html$' -Recurse
    $prose += Add-Files '.claude/rules' '\.md$' -Recurse
    $prose += Add-Files '.claude/skills' '\.md$' -Recurse
    foreach ($d in @('packages', 'scripts', 'provisioning', 'tests', 'config')) {
        $prose += Add-Files $d '^CLAUDE\.md$' -Recurse | Where-Object { $_ -notmatch '/node_modules/|^provisioning/desktop/' }
    }
    $code += Add-Files 'scripts' '\.(ps1|sh)$' -Recurse
    $code += Add-Files 'provisioning' '\.(sh|ya?ml|tpl)$|Dockerfile$' -Recurse | Where-Object { $_ -notmatch '^provisioning/desktop/' }
    $code += Add-Files '.github/workflows' '\.ya?ml$'
    $code += Add-Files 'tests' 'Dockerfile$' -Recurse
    # Pruefer mit eigenen Beispiel-Versionen (Selbst-Asserts, Fixtures); compose.yml/master.Dockerfile: contract_lint 33.
    $skip = @('scripts/contract_lint.ps1', 'scripts/lib/version_pins.ps1', 'scripts/dev/version_pin_lint_test.ps1',
              'scripts/dev/test_stack_test.ps1', 'provisioning/compose/compose.yml', 'provisioning/compose/master.Dockerfile')
    return @{ prose = @($prose | Sort-Object -Unique); code = @($code | Where-Object { $skip -notcontains $_ } | Sort-Object -Unique) }
}

function Get-VersionPinIssues([string]$Root) {
    $Root = (Resolve-Path $Root).Path.TrimEnd('\', '/')
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $issues = New-Object System.Collections.Generic.List[string]
    $pins = Get-RuntimePins $Root
    $pat = Get-VersionPatterns
    $files = Get-VersionPinFiles $Root
    if ($files.prose.Count -eq 0 -or $files.code.Count -eq 0) { $issues.Add("Versions-Pruefung: keine Dateien gefunden ($($files.prose.Count) Doku, $($files.code.Count) Code) -- Scan tot."); return $issues }

    $found = @{}   # "file|kind|version" -> @{count; lines}
    foreach ($set in @(@{ list = $files.prose; rx = @($pat.image) + @($pat.prose); code = $false }, @{ list = $files.code; rx = $pat.image; code = $true })) {
        foreach ($rel in $set.list) {
            $no = 0
            foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $Root $rel), $u8)) {
                $no++
                if ($set.code -and $line -match '^\s*(#|//)') { continue }
                $seen = @{}   # Trefferstelle -> eine Nennung zaehlt einmal, auch wenn zwei Muster sie treffen
                foreach ($p in $set.rx) {
                    foreach ($m in [regex]::Matches($line, $p.rx)) {
                        $v = $m.Groups[1].Value
                        if ($v -eq $pins[$p.kind] -or $seen.ContainsKey($m.Groups[1].Index)) { continue }
                        $seen[$m.Groups[1].Index] = $true
                        $k = "$rel|$($p.kind)|$v"
                        if (-not $found.ContainsKey($k)) { $found[$k] = @{ count = 0; lines = @() } }
                        $found[$k].count++; $found[$k].lines += $no
                    }
                }
            }
        }
    }

    $allow = @{}
    $alPath = Join-Path $Root 'scripts/build/version_pin_allowlist.json'
    if (Test-Path $alPath) {
        foreach ($e in ([System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json).allow) {
            $k = "$($e.file)|$($e.kind)|$($e.version)"
            if ([string]$e.reason -notmatch '\S{3}' -or [string]$e.reason -match '^TODO') { $issues.Add("version_pin_allowlist: '$k' ohne Grund.") }
            $allow[$k] = [int]$e.count
        }
    }
    $label = @{ N8n = 'n8n-Version'; Pg = 'PostgreSQL-Version'; Node = 'Node.js-Version' }
    foreach ($k in ($found.Keys | Sort-Object)) {
        $p = $k -split '\|'
        $where = "$($p[0]):$($found[$k].lines -join ',')"
        if (-not $allow.ContainsKey($k)) { $issues.Add("$where`: $($label[$p[1]]) '$($p[2])' != Pin '$($pins[$p[1]])' (provisioning/provision.sh) -- angleichen; ein frueherer Stand kommt mit Grund in scripts/build/version_pin_allowlist.json.") }
        elseif ($allow[$k] -ne $found[$k].count) { $issues.Add("$where`: '$($p[2])' $($found[$k].count)x gefunden, version_pin_allowlist sagt $($allow[$k]) -- count anpassen.") }
    }
    foreach ($k in ($allow.Keys | Sort-Object)) { if (-not $found.ContainsKey($k)) { $issues.Add("version_pin_allowlist-ORPHAN '$k' -- nicht (mehr) vorhanden, Eintrag entfernen.") } }
    return $issues
}
