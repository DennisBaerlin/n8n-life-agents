#Requires -Version 5.1
# standin_lint.ps1 -- Ersatz-Tests brauchen ein benanntes echtes Gegenstueck (hartes Gate, Regel -> tests/CLAUDE.md).
# Ein Test, der gegen eine Attrappe laeuft oder dem geprueften Programm einen Wert von Hand mitgibt, beweist den echten
# Weg nicht. Der Lint macht die Luecke beim Schreiben sichtbar:
#   (A) jede Attrappe tests/**/fake_* traegt in den ersten 15 Zeilen `# real-path-test: <Repo-Pfad>` (die Datei muss
#       existieren: der Test, der dieselben Eingaben durch das echte Gegenstueck schickt) oder
#       `# real-path-test: none (<Grund>)`;
#   (B) in .github/workflows/*.yml und tests/**/*.sh braucht `docker exec -e|--env NAME=...` sowie `NAME=... bash
#       <...>provision.sh|install.sh` in derselben oder der Zeile davor `# hand-injected: <Grund>` (warum der echte Weg
#       den Wert genauso liefert oder wo er getrennt geprueft ist);
#   (C)/(D) Stubs ohne den Namen fake_ und `export NAME=<fester Wert>` (Ausnahmeliste tests/util/standin_allowlist.json);
#   (E) kein erfundener Wert in der Form eines echten Anbieter-Schluessels (Tailscale, Telegram, Anthropic, GitHub) in
#       tests/, scripts/, provisioning/, packages/, docs/, config/, .github/, .env.example (GitHub Secret Scanning meldet ihn;
#       Muster unveroeffentlicht: docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns).
# Aufruf: .\scripts\standin_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/standin_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
function Rel([string]$p) { return $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }

$testsDir = Join-Path $Root 'tests'
$testFiles = @()
if (Test-Path $testsDir) {
    $testFiles = @(Get-ChildItem $testsDir -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' })
}

# --- (A) Attrappen nennen den Test des echten Gegenstuecks ---
$fakes = @($testFiles | Where-Object { $_.Name -like 'fake_*' })
foreach ($f in $fakes) {
    $head = @([System.IO.File]::ReadAllLines($f.FullName, $u8) | Select-Object -First 15)
    $m = $null
    foreach ($line in $head) { $m = [regex]::Match($line, 'real-path-test:\s*(.*)$'); if ($m.Success) { break } }
    $rel = Rel $f.FullName
    if (-not $m -or -not $m.Success) {
        Fail "${rel}: Attrappe ohne Kopfzeile '# real-path-test: <Repo-Pfad des Tests gegen das echte Gegenstueck>' (oder 'none (<Grund>)')"
        continue
    }
    $val = $m.Groups[1].Value.Trim()
    if ($val -match '^none\b') {
        if ($val -notmatch '^none\s*\(\s*\S[^)]*\)') { Fail "${rel}: 'real-path-test: none' braucht einen Grund in Klammern" }
        continue
    }
    $target = ($val -split '\s+')[0]
    if (-not $target -or -not (Test-Path (Join-Path $Root $target) -PathType Leaf)) {
        Fail "${rel}: real-path-test zeigt auf '$target', die Datei gibt es nicht"
    }
}

# --- (B) von Hand mitgegebene Werte vor dem geprueften Aufruf brauchen eine Begruendung ---
$scan = @($testFiles | Where-Object { $_.Extension -eq '.sh' -and $_.Name -notlike 'fake_*' })
$wfDir = Join-Path $Root '.github\workflows'
if (Test-Path $wfDir) { $scan += @(Get-ChildItem $wfDir -File -Filter '*.yml') }
$rxExec   = [regex]'docker\s+exec\b.*?\s(?:-e|--env)[\s=]+([A-Za-z_][A-Za-z0-9_]*)='
$rxPrefix = [regex]'(?:^|[\s;&|(])([A-Z_][A-Z0-9_]*)=\S+\s+(?:[A-Z_][A-Z0-9_]*=\S+\s+)*bash\s+\S*(?:provision|install)\.sh\b'
$rxReason = [regex]'#\s*hand-injected:\s*\S'
$hits = 0
foreach ($f in $scan) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = $rxExec.Match($lines[$i]); if (-not $m.Success) { $m = $rxPrefix.Match($lines[$i]) }
        if (-not $m.Success) { continue }
        $hits++
        $prev = if ($i -gt 0) { $lines[$i - 1] } else { '' }
        if ($rxReason.IsMatch($lines[$i]) -or $rxReason.IsMatch($prev)) { continue }
        Fail "$(Rel $f.FullName):$($i + 1): $($m.Groups[1].Value) wird dem geprueften Aufruf von Hand mitgegeben; '# hand-injected: <Grund>' in derselben oder der Zeile davor fehlt"
    }
}

# --- (C) Stubs ohne den Namen fake_: Attrappen in tests/mock_runtime, tests/mock_reach und PATH-Attrappen ---
# --- (D) `export NAME=<fester Wert>`: ein von Hand mitgegebener Wert vor dem geprueften Aufruf ---
# Fail-closed mit Ausnahmeliste tests/util/standin_allowlist.json (Schluessel <Datei>|stub bzw. <Datei>|<NAME>, Wert = welcher
# echte Test fehlt). Die Liste darf nur schrumpfen: ein Eintrag ohne Fund ist ein Fehler. Here-Doc-Rumpf zaehlt nicht.
$alPath = Join-Path $Root 'tests\util\standin_allowlist.json'
$allow = @{}
if (Test-Path $alPath) {
    $al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
    if ($al.entries) { foreach ($p in $al.entries.PSObject.Properties) { $allow[$p.Name] = [string]$p.Value } }
}
$used = @{}
$plumbing = @('LANG', 'LC_ALL', 'GUM_DISABLE', 'PATH')
$rxHere = [regex]'(?<!<)<<-?\s*[''"]?([A-Za-z_][A-Za-z0-9_]*)[''"]?'
$rxPathStub = [regex]'(?:^|[\s;(])(?:export\s+)?PATH="[^"]*\$[^"]*:\$\{?PATH\}?"'
$rxChmodStub = [regex]'chmod\s+\+x\s+"?\$\{?\w+\}?/(?:bin|shim)\b'
$rxExport = [regex]'^\s*export\s+(.*)$'
$rxAssign = [regex]'([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|''[^'']*''|[^\s;]*)'
$shFiles = @($testFiles | Where-Object { $_.Extension -eq '.sh' -and $_.Name -notlike 'fake_*' })
foreach ($f in $shFiles) {
    $rel = Rel $f.FullName
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
    $inDir = $rel -match '^tests/(mock_runtime|mock_reach)/'
    $stub = $inDir
    $exports = New-Object System.Collections.Generic.List[object]
    $tag = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($tag) { if ($line.Trim() -eq $tag) { $tag = $null }; continue }
        if ($line -match '^\s*#') { continue }
        $hm = $rxHere.Match($line); if ($hm.Success) { $tag = $hm.Groups[1].Value }
        if ($rxPathStub.IsMatch($line) -or $rxChmodStub.IsMatch($line)) { $stub = $true }
        $em = $rxExport.Match($line)
        if (-not $em.Success) { continue }
        foreach ($am in $rxAssign.Matches($em.Groups[1].Value)) {
            $name = $am.Groups[1].Value; $val = $am.Groups[2].Value
            if ($plumbing -contains $name -or $val -match '[$`]') { continue }
            $exports.Add(@{ Name = $name; Line = $i })
        }
    }
    if ($stub) {
        $head = @($lines | Select-Object -First 15)
        $m = $null
        foreach ($l in $head) { $m = [regex]::Match($l, 'real-path-test:\s*(.*)$'); if ($m.Success) { break } }
        $key = "$rel|stub"
        if ($m -and $m.Success) {
            $val = $m.Groups[1].Value.Trim()
            if ($val -match '^none\b') {
                if ($val -notmatch '^none\s*\(\s*\S[^)]*\)') { Fail "${rel}: 'real-path-test: none' braucht einen Grund in Klammern" }
            } else {
                $target = ($val -split '\s+')[0]
                if (-not $target -or -not (Test-Path (Join-Path $Root $target) -PathType Leaf)) { Fail "${rel}: real-path-test zeigt auf '$target', die Datei gibt es nicht" }
            }
        } elseif ($allow.ContainsKey($key)) { $used[$key] = $true }
        else { Fail "${rel}: PATH-Attrappe/Stub ohne Kopfzeile '# real-path-test: <Repo-Pfad des Tests gegen das echte Gegenstueck>' (oder 'none (<Grund>)'), nicht in tests/util/standin_allowlist.json" }
    }
    foreach ($e in $exports) {
        $key = "$rel|$($e.Name)"
        $prev = if ($e.Line -gt 0) { $lines[$e.Line - 1] } else { '' }
        if ($rxReason.IsMatch($lines[$e.Line]) -or $rxReason.IsMatch($prev)) { $hits++; continue }
        if ($allow.ContainsKey($key)) { $used[$key] = $true; continue }
        Fail "${rel}:$($e.Line + 1): export $($e.Name)= gibt dem geprueften Aufruf einen festen Wert von Hand mit; '# hand-injected: <Grund>' in derselben oder der Zeile davor fehlt (oder Eintrag in tests/util/standin_allowlist.json)"
    }
}
foreach ($k in $allow.Keys) {
    if (-not $allow[$k].Trim()) { Fail "standin_allowlist: Eintrag '$k' ohne Grund (welcher echte Test fehlt?)" }
    if (-not $used.ContainsKey($k)) { Fail "standin_allowlist: Eintrag '$k' ist veraltet (kein Fund mehr) -> entfernen; die Liste darf nur schrumpfen" }
}

# --- (E) erfundene Werte nie in der Form echter Anbieter-Schluessel ---
# GitHub Secret Scanning meldet solche Werte als echte Schluessel (Alarm beim Owner, Partner-Meldung an den Anbieter);
# GitHub veroeffentlicht die Muster nicht, darum hier die bekannte Form jedes Anbieters, eng genug fuer Produkt-Code
# (Glob tskey-?*, Regex [0-9]{5,}:...). Echte Schluessel faengt gitleaks; dieser Teil haelt die Attrappen-Werte neutral.
$secretShapes = [ordered]@{
    'Tailscale' = '(?<![A-Za-z0-9])tskey-(?:auth|client|api|scim|webhook)-[A-Za-z0-9]'
    'Telegram'  = '(?<![0-9])[0-9]{8,10}:[A-Za-z0-9_-]{30,}'
    'Anthropic' = 'sk-ant-(?:api|admin|sid)[0-9]{2}-'
    'GitHub'    = '(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
}
$textExt = @('.sh', '.ps1', '.psm1', '.psd1', '.js', '.mjs', '.cjs', '.ts', '.json', '.yml', '.yaml', '.toml', '.md', '.sql', '.env', '.example', '.txt', '.py', '.rs', '.html', '.css', '.tpl', '.conf', '')
$shapeFiles = @()
foreach ($d in @('tests', 'scripts', 'provisioning', 'packages', 'docs', 'config', '.github')) {
    $p = Join-Path $Root $d
    if (Test-Path $p) {
        $shapeFiles += @(Get-ChildItem $p -Recurse -File | Where-Object {
            $_.FullName -notmatch '[\\/](node_modules|target|public)[\\/]' -and $textExt -contains $_.Extension.ToLowerInvariant() })
    }
}
$shapeFiles += @(Get-ChildItem $Root -File -Filter '.env.example' -ErrorAction SilentlyContinue)
foreach ($f in $shapeFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, $u8)
    foreach ($k in $secretShapes.Keys) {
        foreach ($m in [regex]::Matches($txt, $secretShapes[$k])) {
            $ln = ($txt.Substring(0, $m.Index) -split "`n").Count
            Fail "$(Rel $f.FullName):${ln}: Wert in der Form eines echten $k-Schluessels (GitHub Secret Scanning meldet ihn als Leck) -> neutral erfinden, z. B. test-fake-... statt des Anbieter-Praefixes"
        }
    }
}

if ($fails -eq 0) { Write-Host "standin_lint: OK ($($fakes.Count) Attrappe(n) markiert, $hits begruendete Hand-Wert(e), $($allow.Count) Ausnahme(n))" -ForegroundColor Green }
else { Write-Host "standin_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
