#Requires -Version 5.1
# hook_autoload_lint.ps1 -- zwei Gesetze fuer das Hook-Umfeld der .pre-commit-config.yaml (hartes Gate).
# (1) Autoload: Hook-Skripte nutzen keine Befehle, die Windows PowerShell 5.1 per Modul-Autoload holt und die mit einem geerbten PSModulePath
#   fehlen. In der CI startet prek unter pwsh 7 jeden Hook als `powershell -NoProfile -File ...`; 5.1 erbt den PSModulePath von pwsh 7 und
#   findet Funktionen, die erst beim ersten Aufruf aus einem Modul geladen werden, nicht mehr ("The term 'Get-FileHash' is not recognized").
#   Betroffen sind die Funktionen der Module unter $PSHOME\Modules, nicht die in den Host eingebauten Cmdlets. Die Liste der Befehle liest die
#   Pruefung beim Lauf aus den Manifesten unter $PSHOME\Modules; ein paar bekannte Namen stehen fest dabei, falls die Liste nicht lesbar ist.
#   Definiert ein Skript im Umfeld die Funktion selbst, zaehlt der Aufruf nicht. Statt Get-FileHash: Get-FileSha256 aus scripts/lib/hash.ps1.
#   Ausnahme einer Zeile: `# hook-autoload: ok <Grund>` am Zeilenende. Dieses Gesetz gilt nur in Windows PowerShell 5.1 (Host der Hooks).
# (2) Dateifilter: Ein Pruef-Haken (Skript *_lint.ps1, config_test, gen_fn_catalog, test_stack_test, build.ps1), der beim Commit nur bei
#   `files:` laeuft, muss jede Datei treffen, die er liest -- sonst faellt die Regel beim Commit still weg. "Liest" heisst: die Skripte selbst
#   samt Dot-Sourcing und jeder Repo-Pfad, den sie als Zeichenkette nennen (auch zusammengesetzt aus Join-Path; ein Ordner oder Muster meint
#   alle getrackten Dateien darunter). Dazu braucht er den Zwilling `<id>-full` (Stufe pre-push, always_run, derselbe Aufruf ohne -Staged): `files:` sieht
#   reine Loeschungen und Merge-Commits nicht. Ausnahmen stehen als Kommentarzeile im Haken, mit Grund; eine verwaiste Ausnahme ist rot:
#     # read-ok: <pfad>[, <pfad>] -- <Grund>   genannt, aber nicht (oder nicht vollstaendig) gelesen
#     # skip-lib: <bibliothek.ps1> -- <Grund>   eingebunden, aber ihre lesenden Funktionen ruft der Haken nicht auf: ihre Pfade und ihr
#                                              ls-files zaehlen nicht (die Datei selbst muss der Filter treffen)
#     # ls-files-ok: <Grund>                   Skript listet getrackte Dateien (`ls-files`): wie der Filter das deckt
#     # no-full: <Grund>                       kein Zwilling noetig
# Hook-Umfeld = jedes Skript, das ein Eintrag `entry: powershell ... -File <skript>` startet, und alles, was es per Dot-Sourcing
#   (`. <pfad>.ps1`) laedt. Skripte, die ein Hook per `&` oder `-File` als Kind startet, folgt die Pruefung nicht.
# Aufruf: .\scripts\hook_autoload_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/hook_autoload_lint_test.ps1; ohne .git zaehlen
#   alle Dateien des Baums als getrackt). Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$cfgFile = Join-Path $Root '.pre-commit-config.yaml'
if (-not (Test-Path $cfgFile)) { Fail "fehlt: $cfgFile"; Write-Host "hook_autoload_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$cfg = [System.IO.File]::ReadAllText($cfgFile, $u8)

function Rel([string]$p) { $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
function Get-Closure([string]$path, $seen) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $full = (Resolve-Path -LiteralPath $path).Path
    if ($seen.Contains($full)) { return }
    [void]$seen.Add($full)
    $dir = Split-Path $full -Parent
    foreach ($line in [System.IO.File]::ReadAllLines($full, $u8)) {
        $m = [regex]::Match($line, '^\s*\.\s+.*?([A-Za-z0-9_$./\\-]+\.ps1)[''")]')
        if (-not $m.Success) { continue }
        # "$PSScriptRoot\lib\x.ps1" und $RepoRoot\scripts\x.ps1: die Variable vorn weglassen, der Rest ist ein Pfad ab Skriptordner oder Wurzel.
        $name = $m.Groups[1].Value -replace '^\$[A-Za-z]+[\\/]', ''
        foreach ($cand in @((Join-Path $dir $name), (Join-Path $Root $name), (Join-Path (Join-Path $Root 'scripts') $name), (Join-Path $dir (Split-Path $name -Leaf)))) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { Get-Closure $cand $seen; break }
        }
    }
}

# Ein Haken = die Zeilen von "- id:" bis zum naechsten "- id:".
$hooks = @(foreach ($block in [regex]::Split($cfg, '(?m)^(?=\s*- id:)')) {
    $id = [regex]::Match($block, '^\s*- id:\s*(\S+)')
    if (-not $id.Success) { continue }
    $files = [regex]::Match($block, '(?m)^\s*files:[ \t]*([^\r\n]+?)\s*$')
    $stages = [regex]::Match($block, '(?m)^\s*stages:\s*\[([^\]]*)\]')
    @{
        Id     = $id.Groups[1].Value
        Script = [regex]::Match($block, '(?m)^\s*entry:\s*powershell[^\r\n]*?-File\s+(\S+\.ps1)').Groups[1].Value
        # Aufruf ab dem Skript ohne -Staged (der Commit-Haken sieht damit nur das Gestagte, der Zwilling alles).
        Call   = ([regex]::Match($block, '(?m)^\s*entry:\s*powershell[^\r\n]*?-File\s+([^\r\n]+?)\s*$').Groups[1].Value -replace '\s+-Staged\b', '')
        Files  = $files.Groups[1].Value.Trim("'`"")
        Stages = @($stages.Groups[1].Value -split '\s*,\s*' | Where-Object { $_ })
        Always = $block -match '(?m)^\s*always_run:\s*true'
        Block  = $block
    }
})

# --- (1) Autoload ----------------------------------------------------------------------------------------------
$autoInfo = 'Autoload uebersprungen (nur Windows PowerShell 5.1)'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Die Manifeste werden per Pfad gelesen, damit ein geerbter PSModulePath (pwsh 7) die Liste nicht veraendert.
    $auto = @{}
    $manifests = @(Get-ChildItem "$PSHOME\Modules" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "$($_.Name).psd1" } | Where-Object { Test-Path -LiteralPath $_ })
    if ($manifests.Count -gt 0) {
        foreach ($m in (Get-Module -ListAvailable $manifests -ErrorAction SilentlyContinue)) {
            foreach ($c in $m.ExportedFunctions.Keys) { $auto[$c] = $m.Name }
        }
    }
    foreach ($pair in @(@('Get-FileHash', 'Microsoft.PowerShell.Utility'), @('Expand-Archive', 'Microsoft.PowerShell.Archive'), @('Compress-Archive', 'Microsoft.PowerShell.Archive'),
                        @('Test-NetConnection', 'NetTCPIP'), @('Resolve-DnsName', 'DnsClient'), @('Get-NetTCPConnection', 'NetTCPIP'))) {
        if (-not $auto.ContainsKey($pair[0])) { $auto[$pair[0]] = $pair[1] }
    }

    $entries = @($hooks | ForEach-Object { $_.Script } | Where-Object { $_ } | Sort-Object -Unique)
    $envFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $entries) { Get-Closure (Join-Path $Root $e) $envFiles }

    if ($auto.Count -lt 200) { Write-Warning "nur $($auto.Count) Autoload-Funktionen im 5.1-Host gelesen: es gilt die kurze feste Liste" }
    # Definiert ein Skript im Umfeld die Funktion selbst, zaehlt der Aufruf nicht.
    $defined = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $envFiles) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        foreach ($fd in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { [void]$defined.Add($fd.Name) }
    }
    foreach ($f in $envFiles) {
        $text = [System.IO.File]::ReadAllText($f, $u8)
        $lines = $text -split "`r?`n"
        foreach ($k in [System.Management.Automation.PSParser]::Tokenize($text, [ref]$null)) {
            if ($k.Type -ne 'Command' -or -not $auto.ContainsKey($k.Content) -or $defined.Contains($k.Content)) { continue }
            if ($lines[$k.StartLine - 1] -match '#\s*hook-autoload:\s*ok\s+\S') { continue }
            $hint = if ($k.Content -eq 'Get-FileHash') { ' -> Get-FileSha256 aus scripts/lib/hash.ps1' } else { ' -> .NET statt des Moduls' }
            Fail "$(Rel $f):$($k.StartLine): $($k.Content) ($($auto[$k.Content])) steht im Hook-Umfeld; Windows PowerShell 5.1 findet es unter pwsh 7 (CI) nicht$hint"
        }
    }
    $autoInfo = "$($entries.Count) Hook-Skript(e), $($envFiles.Count) Datei(en) im Umfeld, $($auto.Count) Autoload-Befehle"
}

# --- (2) Dateifilter ---------------------------------------------------------------------------------------------
if (Test-Path (Join-Path $Root '.git')) { $tracked = @(git -C $Root -c core.quotepath=off ls-files) }
else { $tracked = @(Get-ChildItem $Root -Recurse -File -Force | ForEach-Object { Rel $_.FullName }) }
$TopDirs = '^(packages|provisioning|scripts|tests|docs|config|\.github|\.claude)(/|$)'
# Dateien in der Wurzel zaehlen mit; die Hook-Konfiguration selbst liest jeder Lint-Test nur als Fixture-Namen.
$rootFiles = @($tracked | Where-Object { -not $_.Contains('/') })

# Wert eines Pfad-Ausdrucks: Zeichenkette oder (verschachteltes) Join-Path. $PSScriptRoot als Basis ist der Ordner des Skripts (Marke
# "@dir"), jede andere Variable die Wurzel.
function Get-PathValue($node) {
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($node.VariablePath.UserPath -eq 'PSScriptRoot') { return '@dir' }
        return ''
    }
    if ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $els = $node.Pipeline.PipelineElements
        if ($els.Count -eq 1) { return Get-PathValue $els[0] }
        return ''
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { return Get-PathValue $node.Expression }
    if ($node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Join-Path') {
        $parts = @($node.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { Get-PathValue $_ })
        return (@($parts | Where-Object { $_ }) -join '/')
    }
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $node.Value }
    return ''
}
$readCache = @{}
function Get-PathLiterals([string]$file) {
    if ($readCache.ContainsKey($file)) { return $readCache[$file] }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $joins = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Join-Path' }, $true))
    $strings = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))
    $inside = { param($x) foreach ($j in $joins) { if ($j -ne $x -and $x.Extent.StartOffset -ge $j.Extent.StartOffset -and $x.Extent.EndOffset -le $j.Extent.EndOffset) { return $true } }; return $false }
    # Eigenschafts- und Methodennamen (`$x.config`) und nackte Hashtable-Schluessel sind im Syntaxbaum auch Zeichenketten, aber kein Pfad.
    $isName = { param($x)
        $p = $x.Parent
        if ($p -is [System.Management.Automation.Language.MemberExpressionAst]) { return [object]::ReferenceEquals($p.Member, $x) }
        if ($p -is [System.Management.Automation.Language.HashtableAst]) { return $x.StringConstantType -eq 'BareWord' }
        return $false
    }
    $values = @($joins | Where-Object { -not (& $inside $_) } | ForEach-Object { Get-PathValue $_ }) + @($strings | Where-Object { -not (& $inside $_) -and -not (& $isName $_) } | ForEach-Object { $_.Value })
    $out = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($v in $values) {
        if (-not $v -or $v -match '\s') { continue }
        $n = $v.Replace('\', '/') -replace '^\$\{?PSScriptRoot\}?/', '@dir/'
        if ($n.StartsWith('@dir/')) {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($seg in ((Rel (Split-Path $file -Parent)) + '/' + $n.Substring(5)) -split '/') {
                if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } } elseif ($seg -and $seg -ne '.') { $parts.Add($seg) }
            }
            $n = $parts -join '/'
        } else { $n = $n -replace '^\$\{?[A-Za-z_:]+\}?/', '' -replace '^(\.{1,2}/)+', '' }
        if ($n -notmatch $TopDirs -and $rootFiles -cnotcontains $n) { continue }
        $n = ($n -replace '\$.*$', '').TrimEnd('/')
        [void]$out.Add($n)
    }
    $readCache[$file] = @($out)
    return $readCache[$file]
}
$expandCache = @{}
function Expand-Read([string]$lit) {
    if ($expandCache.ContainsKey($lit)) { return $expandCache[$lit] }
    if ($lit.Contains('*')) {
        $rx = '^' + [regex]::Escape($lit).Replace('\*\*', '.*').Replace('\*', '[^/]*') + '(/.*)?$'
        $hit = @(foreach ($t in $tracked) { if ($t -cmatch $rx) { $t } })
    } else {
        $prefix = "$lit/"
        $hit = @(foreach ($t in $tracked) { if ($t -ceq $lit -or $t.StartsWith($prefix, [StringComparison]::Ordinal)) { $t } })
    }
    $expandCache[$lit] = $hit
    return $hit
}

$checked = 0
foreach ($h in $hooks) {
    if (-not $h.Script -or (Split-Path $h.Script -Leaf) -notmatch '(_lint|^config_test|^gen_fn_catalog|^test_stack_test|^build)\.ps1$') { continue }
    $notes = @{}
    foreach ($m in [regex]::Matches($h.Block, '(?m)^\s*#\s*(read-ok|skip-lib|ls-files-ok|no-full):[ \t]*([^\r\n]*)')) {
        if (-not $notes.ContainsKey($m.Groups[1].Value)) { $notes[$m.Groups[1].Value] = @() }
        $notes[$m.Groups[1].Value] += $m.Groups[2].Value.Trim()
    }
    $commitStage = $h.Stages.Count -eq 0 -or $h.Stages -contains 'pre-commit'
    if (-not $commitStage -or -not $h.Files) {
        foreach ($k in $notes.Keys) { Fail "Haken $($h.Id): Ausnahme '$k' ohne Wirkung (kein Datei-Filter in der Commit-Stufe) -- Zeile entfernen" }
        continue
    }
    $checked++
    $filter = $h.Files
    if ($filter -match '^[|>]') { Fail "Haken $($h.Id): files-Filter bitte in einer Zeile schreiben, ein YAML-Block wird hier nicht gelesen"; continue }
    $closure = New-Object 'System.Collections.Generic.HashSet[string]'
    Get-Closure (Join-Path $Root $h.Script) $closure
    if ($closure.Count -eq 0) { Fail "Haken $($h.Id): Skript $($h.Script) fehlt"; continue }

    $excused = @{}
    foreach ($line in @($notes['read-ok'])) {
        if ($null -eq $line) { continue }
        $parts = $line -split '\s+--\s+', 2
        if ($parts.Count -ne 2 -or -not $parts[1].Trim()) { Fail "Haken $($h.Id): read-ok ohne Grund ('<pfad> -- <Grund>'): $line"; continue }
        foreach ($p in ($parts[0] -split '\s*,\s*')) { $excused[$p] = $false }
    }
    $skipped = @{}
    foreach ($line in @($notes['skip-lib'])) {
        if ($null -eq $line) { continue }
        $parts = $line -split '\s+--\s+', 2
        if ($parts.Count -ne 2 -or -not $parts[1].Trim()) { Fail "Haken $($h.Id): skip-lib ohne Grund ('<bibliothek> -- <Grund>'): $line"; continue }
        $skipped[$parts[0].Trim()] = $false
    }
    $reads = @{}
    $ownFiles = @()
    foreach ($f in $closure) {
        $rel = Rel $f
        if ($rel -cnotmatch $filter) { Fail "Haken $($h.Id): files-Filter trifft $rel nicht, das Skript gehoert aber zum Haken (Aufruf oder Dot-Sourcing)" }
        if ($skipped.ContainsKey($rel) -and $rel -cne $h.Script) { $skipped[$rel] = $true; continue }
        $ownFiles += $f
        foreach ($lit in (Get-PathLiterals $f)) { $reads[$lit] = $rel }
    }
    foreach ($p in $skipped.Keys) { if (-not $skipped[$p]) { Fail "Haken $($h.Id): skip-lib '$p' ist verwaist (keine eingebundene Bibliothek) -- Eintrag entfernen" } }
    foreach ($lit in ($reads.Keys | Sort-Object)) {
        $miss = @(foreach ($t in (Expand-Read $lit)) { if ($t -cnotmatch $filter) { $t } })
        if ($miss.Count -eq 0) { continue }
        if ($excused.ContainsKey($lit)) { $excused[$lit] = $true; continue }
        Fail "Haken $($h.Id): $($reads[$lit]) liest '$lit', der files-Filter trifft $($miss.Count) Datei(en) davon nicht (z. B. $($miss[0])) -- Filter erweitern oder '# read-ok: $lit -- <Grund>'"
    }
    foreach ($p in $excused.Keys) { if (-not $excused[$p]) { Fail "Haken $($h.Id): read-ok '$p' ist verwaist (nichts ungedeckt) -- Eintrag entfernen" } }

    $listsTree = $false
    foreach ($f in $ownFiles) {
        if (@([System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText($f, $u8), [ref]$null) | Where-Object { $_.Type -ne 'Comment' -and $_.Content -ceq 'ls-files' }).Count) { $listsTree = $true; break }
    }
    $lsNote = "$(@($notes['ls-files-ok']) -join '')"
    if ($listsTree -and -not $lsNote) { Fail "Haken $($h.Id): das Skript listet getrackte Dateien (ls-files), das sieht kein Pfad-Abgleich -- '# ls-files-ok: <wie der Filter die Dateien deckt>' oder always_run" }
    if (-not $listsTree -and $notes.ContainsKey('ls-files-ok')) { Fail "Haken $($h.Id): ls-files-ok ist verwaist (kein ls-files im Skript)" }

    $twin = @($hooks | Where-Object { $_.Id -ceq "$($h.Id)-full" })
    $noFull = "$(@($notes['no-full']) -join '')"
    if ($twin.Count -eq 0) {
        if (-not $noFull) { Fail "Haken $($h.Id): kein Zwilling $($h.Id)-full (stages: [pre-push], always_run: true) -- Loeschungen und Merge-Commits sieht der files-Filter nicht" }
    } else {
        if ($notes.ContainsKey('no-full')) { Fail "Haken $($h.Id): no-full ist verwaist, der Zwilling existiert" }
        $t = $twin[0]
        if ($t.Call -cne $h.Call -or -not $t.Always -or $t.Files -or $t.Stages.Count -ne 1 -or $t.Stages[0] -cne 'pre-push') {
            Fail "Haken $($t.Id): der Zwilling braucht denselben Aufruf (Skript und Argumente, ohne -Staged), always_run: true, stages: [pre-push] und keinen files-Filter"
        }
    }
}

if ($fails -eq 0) { Write-Host "hook_autoload_lint: OK ($autoInfo; $checked Pruef-Haken mit Dateifilter gedeckt)" -ForegroundColor Green }
else { Write-Host "hook_autoload_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
