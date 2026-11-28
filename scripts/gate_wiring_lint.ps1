#Requires -Version 5.1
# gate_wiring_lint.ps1 -- jeder Test in scripts/dev (*_test.ps1) haengt an einem Gate oder sagt im Kopf, warum nicht (hartes Gate).
# Ein Test, den nichts ausfuehrt, bleibt gruen und beweist nichts: er driftet unbemerkt, bis ihn jemand von Hand startet.
#   Gate   = der Dateiname steht in .pre-commit-config.yaml (Commit/Push), in scripts/dev/run_free_gates.ps1 (freie Suiten,
#            daraus baut die CI ihre Matrix) oder in einem Workflow unter .github/workflows; eine Nennung im Kommentar zaehlt nicht.
#   Marker = in den ersten 40 Zeilen eine Zeile `# gate: manual (<Grund>)`: der Test laeuft nur auf Zuruf (echte Schluessel,
#            eigener Docker-Verbund, bezahlte Dienste). Der Grund ist Pflicht und steht dort, wo man den Test oeffnet.
#   Marker UND Gate ist ein Fehler: der Marker waere veraltet und verschwiege, dass der Test laeuft.
# Aufruf: .\scripts\gate_wiring_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/gate_wiring_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# Die Texte, in denen ein Gate den Test beim Namen nennt.
$carriers = New-Object System.Collections.Generic.List[string]
foreach ($rel in @('.pre-commit-config.yaml', 'scripts/dev/run_free_gates.ps1')) {
    $p = Join-Path $Root $rel
    if (Test-Path $p) { $carriers.Add([System.IO.File]::ReadAllText($p, $u8)) }
}
$wf = Join-Path $Root '.github/workflows'
if (Test-Path $wf) {
    foreach ($f in Get-ChildItem $wf -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) { $carriers.Add([System.IO.File]::ReadAllText($f.FullName, $u8)) }
}
# Kommentare der Traeger zaehlen nicht (YAML und PowerShell: `#` am Zeilenanfang oder nach Leerraum): ein Verweis wie
# "lokal dasselbe: <test>" fuehrt nichts aus. Trifft der Schnitt einmal ein `#` in einem Befehl, wird der Lint rot statt still gruen.
$gateText = (($carriers -join "`n") -split "`r?`n" | ForEach-Object { $_ -replace '(^|\s)#.*$', '' }) -join "`n"

$dev = Join-Path $Root 'scripts/dev'
$tests = @()
if (Test-Path $dev) { $tests = @(Get-ChildItem $dev -File -Filter '*_test.ps1') }
$wired = 0; $manual = 0
foreach ($t in $tests) {
    $rel = "scripts/dev/$($t.Name)"
    $isWired = [regex]::IsMatch($gateText, '(?<![\w.-])' + [regex]::Escape($t.Name) + '(?![\w])')
    $head = @([System.IO.File]::ReadAllLines($t.FullName, $u8) | Select-Object -First 40)
    $marker = @($head | Where-Object { $_ -match '^\s*#\s*gate:\s*manual\b' })
    if ($isWired -and $marker.Count -gt 0) { Fail "${rel}: Marker 'gate: manual' steht, aber ein Gate fuehrt den Test aus -> Marker entfernen."; continue }
    if ($isWired) { $wired++; continue }
    if ($marker.Count -eq 0) { Fail "${rel}: haengt an keinem Gate. In .pre-commit-config.yaml, scripts/dev/run_free_gates.ps1 oder einen Workflow eintragen, oder im Kopf '# gate: manual (<Grund>)' setzen."; continue }
    if ($marker[0] -notmatch 'manual\s*\(\s*\S[^)]*\)') { Fail "${rel}: Marker ohne Grund -> '# gate: manual (<Grund>)'."; continue }
    $manual++
}

if ($fails -eq 0) { Write-Host "gate_wiring_lint: OK ($($tests.Count) Test(s): $wired an einem Gate, $manual mit Marker)" -ForegroundColor Green }
else { Write-Host "gate_wiring_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
