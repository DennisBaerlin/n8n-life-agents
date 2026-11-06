#Requires -Version 5.1
# build_ui_tokens.ps1 -- schreibt die Farben aus config/ui.tokens.json als markierten Block in die Datei jeder Oberflaeche
# (Liste und Begruendung: scripts/lib/ui_tokens.ps1). Nur der Block aendert sich, die Marker muessen schon in der Datei stehen.
# Erzeugt ausserdem das Zeichen-Partial der Site (docs/site/layouts/partials/mark.html) aus config/ui.mark.svg.
# Danach bei der Doku-Seite: .\scripts\build_site.ps1 (der Hugo-Output ist getrackt). Die Pruefung im Commit macht
# scripts/ui_token_lint.ps1.
#   .\scripts\build_ui_tokens.ps1            Bloecke schreiben
#   .\scripts\build_ui_tokens.ps1 -Verify    nur vergleichen, Exit-Code = Anzahl veralteter Bloecke
param([switch]$Verify)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'ui_tokens.ps1')
$u8 = [System.Text.UTF8Encoding]::new($false)
$tokens = Read-UiTokens $RepoRoot
$fails = 0
foreach ($s in (Get-UiSurfaces)) {
    $abs = Join-Path $RepoRoot $s.File
    $text = [System.IO.File]::ReadAllText($abs, $u8)
    $rx = Get-UiBlockRegex $s.Name
    $m = $rx.Match($text)
    if (-not $m.Success) { throw "Keine Marker fuer '$($s.Name)' in $($s.File): Zeile '/* ui-tokens:begin $($s.Name) */' und '/* ui-tokens:end */' von Hand einsetzen (Datei geschuetzt? Dann gilt deren Freigabe)." }
    $want = Get-UiBlockText $tokens $s
    if ($m.Value -ceq $want) { Write-Host "  [OK] $($s.Name): aktuell" -ForegroundColor Green; continue }
    if ($Verify) { Write-Host "  [FAIL] $($s.Name): Block in $($s.File) ist veraltet" -ForegroundColor Red; $fails++; continue }
    # MatchEvaluator statt Ersatz-String: im Ersatz-String waeren $-Zeichen aus dem Block Sonderzeichen
    $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($x) $want }, 1)
    [System.IO.File]::WriteAllText($abs, $text, $u8)
    Write-Host "  [neu] $($s.Name): $($s.File)" -ForegroundColor Cyan
}
# Geteilte Bausteine (Get-UiCopies): Quelle wortgleich in jeden Verbraucher
foreach ($c in (Get-UiCopies)) {
    $name = Split-Path $c.Source -Leaf
    $want = Get-UiCopyText $RepoRoot $c
    foreach ($f in $c.Files) {
        $abs = Join-Path $RepoRoot $f
        $text = [System.IO.File]::ReadAllText($abs, $u8)
        $rx = Get-UiCopyRegex $name
        $m = $rx.Match($text)
        if (-not $m.Success) { throw "Keine Marker fuer '$name' in ${f}: Zeile '/* ui-copy:begin $name */' und '/* ui-copy:end */' von Hand einsetzen." }
        if ($m.Value -ceq $want) { Write-Host "  [OK] ${name}: $f aktuell" -ForegroundColor Green; continue }
        if ($Verify) { Write-Host "  [FAIL] ${name}: Kopie in $f ist veraltet" -ForegroundColor Red; $fails++; continue }
        $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($x) $want }, 1)
        [System.IO.File]::WriteAllText($abs, $text, $u8)
        Write-Host "  [neu] ${name}: $f" -ForegroundColor Cyan
    }
}
# Texte aus dem Katalog (Get-UiLocaleBlocks)
foreach ($b in (Get-UiLocaleBlocks)) {
    $abs = Join-Path $RepoRoot $b.File
    $text = [System.IO.File]::ReadAllText($abs, $u8)
    $rx = Get-UiLocaleRegex $b.Name
    $m = $rx.Match($text)
    if (-not $m.Success) { throw "Keine Marker fuer Texte '$($b.Name)' in $($b.File): '/* ui-locale:begin $($b.Name) */' und '/* ui-locale:end */' von Hand einsetzen." }
    $want = Get-UiLocaleText $RepoRoot $b
    if ($m.Value -ceq $want) { Write-Host "  [OK] Texte $($b.Name): aktuell" -ForegroundColor Green; continue }
    if ($Verify) { Write-Host "  [FAIL] Texte $($b.Name): Block in $($b.File) ist veraltet" -ForegroundColor Red; $fails++; continue }
    $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($x) $want }, 1)
    [System.IO.File]::WriteAllText($abs, $text, $u8)
    Write-Host "  [neu] Texte $($b.Name): $($b.File)" -ForegroundColor Cyan
}
# Zeichen-Partial der Site (ganze Datei erzeugt)
$markPaths = @(Get-UiMarkPaths $RepoRoot)
if ($markPaths.Count -eq 0) { throw "Keine <path>-Zeilen in $(Get-UiMarkSourcePath)." }
$markAbs = Join-Path $RepoRoot (Get-UiMarkPartialPath)
$markWant = Get-UiMarkPartialText $markPaths
$markHave = if (Test-Path $markAbs) { [System.IO.File]::ReadAllText($markAbs, $u8) } else { '' }
if ($markHave -ceq $markWant) { Write-Host '  [OK] mark: aktuell' -ForegroundColor Green }
elseif ($Verify) { Write-Host "  [FAIL] mark: $(Get-UiMarkPartialPath) ist veraltet" -ForegroundColor Red; $fails++ }
else { [System.IO.File]::WriteAllText($markAbs, $markWant, $u8); Write-Host "  [neu] mark: $(Get-UiMarkPartialPath)" -ForegroundColor Cyan }
exit $fails
