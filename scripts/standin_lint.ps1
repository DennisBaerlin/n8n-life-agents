#Requires -Version 5.1
# standin_lint.ps1 -- Ersatz-Tests brauchen ein benanntes echtes Gegenstueck (hartes Gate, Regel -> tests/CLAUDE.md).
# Ein Test, der gegen eine Attrappe laeuft oder dem geprueften Programm einen Wert von Hand mitgibt, beweist den echten
# Weg nicht. Der Lint macht die Luecke beim Schreiben sichtbar:
#   (A) jede Attrappe tests/**/fake_* traegt in den ersten 15 Zeilen `# real-path-test: <Repo-Pfad>` (die Datei muss
#       existieren: der Test, der dieselben Eingaben durch das echte Gegenstueck schickt) oder
#       `# real-path-test: none (<Grund>)`;
#   (B) in .github/workflows/*.yml und tests/**/*.sh braucht `docker exec -e|--env NAME=...` sowie `NAME=... bash
#       <...>provision.sh|install.sh` in derselben oder der Zeile davor `# hand-injected: <Grund>` (warum der echte Weg
#       den Wert genauso liefert oder wo er getrennt geprueft ist).
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

if ($fails -eq 0) { Write-Host "standin_lint: OK ($($fakes.Count) Attrappe(n) markiert, $hits begruendete Hand-Wert(e))" -ForegroundColor Green }
else { Write-Host "standin_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
