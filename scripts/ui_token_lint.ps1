#Requires -Version 5.1
# ui_token_lint.ps1 -- eine Farbquelle fuer alle Oberflaechen (hartes Gate, Vorbild scripts/ui_literal_lint.ps1).
# Regeln und Ablauf: docs/reference/ui.md, Skill /ui-task. Mechanik der Bloecke: scripts/lib/ui_tokens.ps1.
# Prueft in dieser Reihenfolge:
#   Selbst-Asserts   stirbt die Erkennung still, bricht der Lint (Kontrast-Formel, Literal-Erkennung, Blockformat).
#   (1) Farbdatei    config/ui.tokens.json: hex und components passen zueinander, jede Kontrast-Paarung nennt echte Tokens,
#                    hell und dunkel haben dieselben Namen.
#   (2) Kontrast     jede Paarung aus $extensions in hell und dunkel; Schwelle am Eintrag (Text 4,5:1, Punkte/Raender 3:1).
#   (3) Bloecke      der erzeugte Block jeder Oberflaeche ist aktuell (sonst: scripts/build_ui_tokens.ps1).
#   (4) Literale     feste Farben (Hex, rgb(), hsl()) unter den Wurzeln aus Get-UiScanRoots, ausserhalb der Bloecke. RATCHET:
#                    jede heute vorhandene Stelle steht je (Datei, Literal) in scripts/build/ui_token_allowlist.json mit
#                    Begruendung. Found > Allowlist = neue Farbe (FAIL), Found < Allowlist = schrumpfen (FAIL), Orphan = FAIL.
#                    Begruendungen: mock:<warum> Nachbau fremder Oberflaeche; derived:<warum> vom Token abgeleitet (Transparenz,
#                    Abdunklung); pilot:<warum> alter Wert, die Umstellung raeumt ihn ab; art:<warum> Zeichnung.
#   (5) Neue Flaechen UI-Datei ausserhalb der registrierten Wurzeln -> FAIL (Oberflaeche in lib/ui_tokens.ps1 eintragen).
#   (6) Bot-Profilbild  das committete JPG ist aus dem aktuellen Zeichen und der Farbdatei abgeleitet (Pruefwert der Quelle).
# -Baseline: druckt die gefundenen Literale als JSON-Geruest (reason:'TODO').
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Substrat.
param([switch]$Baseline, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'ui_tokens.ps1')
$u8 = [System.Text.UTF8Encoding]::new($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Selbst-Asserts ---------------------------------------------------------------------------------------------
if ([Math]::Abs((Get-UiContrast '#000000' '#FFFFFF') - 21) -gt 0.001) { Fail 'Selbst-Assert: Schwarz auf Weiss muss 21:1 ergeben -- Kontrast-Formel defekt' }
if ([Math]::Abs((Get-UiContrast '#777777' '#777777') - 1) -gt 0.001) { Fail 'Selbst-Assert: gleiche Farbe muss 1:1 ergeben -- Kontrast-Formel defekt' }
$selfCases = @(
    @{ c = '.a { color: #fff; }';                  want = @('#fff') }
    @{ c = '<rect fill="#12638A"/>';               want = @('#12638A') }
    @{ c = "var L = '#2A2340';";                   want = @('#2A2340') }
    @{ c = 'box-shadow: 0 1px rgba(0,0,0,.06);';   want = @('rgba(0,0,0,.06)') }
    @{ c = 'a { color: hsl(200 50% 50%); }';       want = @('hsl(200 50% 50%)') }
    @{ c = '<a href="#fab">x</a> &#123; url(#add)'; want = @() }
    @{ c = '#tabs { right: auto; } #app { }';      want = @() }
    @{ c = '.a { color: var(--ink); }';            want = @() }
    @{ c = '/* alt: #123456 */ <!-- #654321 -->';  want = @() }
    @{ c = "/* ui-tokens:begin x (y) */`n:root { --ink: #17212B; }`n/* ui-tokens:end */"; want = @() }
)
foreach ($sc in $selfCases) {
    $got = @(Get-UiColorLiterals $sc.c)
    if (($got -join '|') -ne (@($sc.want) -join '|')) { Fail "Selbst-Assert Literal: '$($sc.c)' -> erwartet [$(@($sc.want) -join ', ')], gefunden [$($got -join ', ')] -- Erkennung defekt" }
}
if (-not (Get-UiBlockRegex 'x').IsMatch("/* ui-tokens:begin x (y) */`n:root { }`n/* ui-tokens:end */")) { Fail 'Selbst-Assert: Block-Muster erkennt den Block nicht' }
if ($fails -gt 0) { Write-Host "ui_token_lint: $fails Fehler (Selbst-Asserts)" -ForegroundColor Red; exit $fails }

# --- (1) Farbdatei ----------------------------------------------------------------------------------------------
$tokens = Read-UiTokens $RepoRoot
$lightNames = @(Get-UiColorNames $tokens 'light')
$darkNames = @(Get-UiColorNames $tokens 'dark')
if ($lightNames.Count -eq 0) { Fail 'Farbdatei: keine Farben in der Gruppe light -- Format geaendert?' }
foreach ($n in $lightNames) { if ($darkNames -notcontains $n) { Fail "Farbdatei: Token '$n' fehlt in dark" } }
foreach ($n in $darkNames) { if ($lightNames -notcontains $n) { Fail "Farbdatei: Token '$n' fehlt in light" } }
foreach ($group in 'light', 'dark') {
    foreach ($n in (Get-UiColorNames $tokens $group)) {
        $v = $tokens.$group.$n.'$value'
        $bytes = 0, 2, 4 | ForEach-Object { [Convert]::ToInt32(([string]$v.hex).TrimStart('#').Substring($_, 2), 16) }
        for ($i = 0; $i -lt 3; $i++) {
            if ([Math]::Abs([double]$v.components[$i] * 255 - $bytes[$i]) -gt 0.6) { Fail "Farbdatei: $group.$n -- hex $($v.hex) passt nicht zu components ($($v.components -join ', '))" }
        }
    }
}

# --- (2) Kontrast -----------------------------------------------------------------------------------------------
$pairs = @($tokens.'$extensions'.'dev.lifeagents.contrast')
if ($pairs.Count -eq 0) { Fail 'Kontrast: keine Paarungen in $extensions -- Pruefung waere tot' }
foreach ($p in $pairs) {
    $unknown = @($p.fg, $p.bg | Where-Object { $lightNames -notcontains $_ })
    if ($unknown.Count -gt 0) { Fail "Kontrast: Paarung nennt unbekanntes Token: $($unknown -join ', ')"; continue }
    if ([double]$p.min -le 0) { Fail "Kontrast: Paarung $($p.fg)/$($p.bg) ohne Schwelle"; continue }
    foreach ($group in 'light', 'dark') {
        $r = Get-UiContrast (Get-UiColorHex $tokens $group $p.fg) (Get-UiColorHex $tokens $group $p.bg)
        if ($Verbose) { Write-Host ("  {0,-5} {1,-13} auf {2,-11} {3:N2}:1 (mind. {4})" -f $group, $p.fg, $p.bg, $r, $p.min) -ForegroundColor DarkGray }
        if ($r -lt [double]$p.min) { Fail ("Kontrast {0}: {1} auf {2} = {3:N2}:1, verlangt {4}:1 ({5})" -f $group, $p.fg, $p.bg, $r, $p.min, $p.use) }
    }
}

# --- (3) Bloecke ------------------------------------------------------------------------------------------------
$surfaces = @(Get-UiSurfaces)
if ($surfaces.Count -eq 0) { Fail 'Bloecke: keine Oberflaeche registriert -- Pruefung waere tot' }
foreach ($s in $surfaces) {
    $abs = Join-Path $RepoRoot $s.File
    if (-not (Test-Path $abs)) { Fail "Block '$($s.Name)': Datei fehlt: $($s.File)"; continue }
    $m = (Get-UiBlockRegex $s.Name).Match([System.IO.File]::ReadAllText($abs, $u8))
    if (-not $m.Success) { Fail "Block '$($s.Name)': keine Marker in $($s.File)"; continue }
    if ($m.Value -cne (Get-UiBlockText $tokens $s)) { Fail "Block '$($s.Name)' in $($s.File) ist veraltet oder von Hand geaendert -- .\scripts\build_ui_tokens.ps1 laufen lassen" }
}
# Geteilte Bausteine: jede Kopie wortgleich mit ihrer Quelle
$copies = @(Get-UiCopies)
$copyFiles = @($copies | ForEach-Object { $_.Files })
foreach ($c in $copies) {
    if (-not (Test-Path (Join-Path $RepoRoot $c.Source))) { Fail "Baustein fehlt: $($c.Source)"; continue }
    $name = Split-Path $c.Source -Leaf
    foreach ($f in $c.Files) {
        $abs = Join-Path $RepoRoot $f
        if (-not (Test-Path $abs)) { Fail "Baustein '$name': Datei fehlt: $f"; continue }
        $m = (Get-UiCopyRegex $name).Match([System.IO.File]::ReadAllText($abs, $u8))
        if (-not $m.Success) { Fail "Baustein '$name': keine Marker in $f"; continue }
        if ($m.Value -cne (Get-UiCopyText $RepoRoot $c)) { Fail "Baustein '$name' in $f ist veraltet oder von Hand geaendert -- .\scripts\build_ui_tokens.ps1 laufen lassen" }
    }
}

# --- (4) Literale -----------------------------------------------------------------------------------------------
$tracked = @(git -c core.quotepath=off -C $RepoRoot ls-files)   # ohne die Option stuenden Umlaut-Pfade in Anfuehrungszeichen, ihre Endung passte nicht
if ($tracked.Count -eq 0) { Fail 'Scope-Selbst-Assert: git ls-files leer -- Scan tot'; exit $fails }
$scanRoots = @(Get-UiScanRoots)
$scanExt = @(Get-UiScanExtensions)
$excluded = @(Get-UiExcludedPrefixes)
function Test-UnderPrefix([string]$Path, [string[]]$Prefixes) { foreach ($p in $Prefixes) { if ($Path.StartsWith($p, [StringComparison]::Ordinal)) { return $true } }; return $false }
$scanFiles = @($tracked | Where-Object { (Test-UnderPrefix $_ $scanRoots) -and -not (Test-UnderPrefix $_ $excluded) -and ($scanExt -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant()) })
if ($scanFiles.Count -eq 0) { Fail 'Scope-Selbst-Assert: keine Oberflaechen-Dateien gefunden -- Scan tot (Pfade?)' }
$found = @{}
foreach ($f in $scanFiles) {
    $abs = Join-Path $RepoRoot $f
    if (-not (Test-Path $abs)) { continue }
    $fileText = [System.IO.File]::ReadAllText($abs, $u8)
    # Marker sind nur in der Datei einer registrierten Oberflaeche gueltig, sonst versteckten sie dort feste Farben vor (3) und (4)
    if ($fileText.Contains('ui-tokens:begin') -and -not (@($surfaces | ForEach-Object { $_.File }) -contains $f)) { Fail "Block-Marker in $f, die Datei ist keine registrierte Oberflaeche (Get-UiSurfaces)" }
    if ($fileText.Contains('ui-copy:begin') -and -not ($copyFiles -contains $f)) { Fail "Baustein-Marker in $f, die Datei ist kein registrierter Verbraucher (Get-UiCopies)" }
    foreach ($lit in (Get-UiColorLiterals $fileText)) {
        $k = "$f|$lit"
        if ($found.ContainsKey($k)) { $found[$k]++ } else { $found[$k] = 1 }
    }
}
if ($Baseline) {
    $entries = foreach ($k in ($found.Keys | Sort-Object)) { $p = $k -split '\|', 2; [ordered]@{ where = $p[0]; literal = $p[1]; count = $found[$k]; reason = 'TODO' } }
    [ordered]@{ _comment = 'Baseline -- Begruendung je Eintrag (mock:|derived:|pilot:|art:<warum>)'; allow = @($entries) } | ConvertTo-Json -Depth 6
    exit 0
}
$alPath = Join-Path (Join-Path (Join-Path $RepoRoot 'scripts') 'build') 'ui_token_allowlist.json'
if (-not (Test-Path $alPath)) { Fail "Allowlist fehlt: $alPath"; Write-Host "ui_token_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
$allow = @{}
foreach ($e in $al.allow) {
    $key = "$([string]$e.where)|$([string]$e.literal)"
    if ([string]$e.reason -notmatch '^(mock|derived|pilot|art):\S') { Fail "allowlist: Eintrag '$key' -- reason muss mock:, derived:, pilot: oder art: mit Begruendung sein (ist '$($e.reason)')" }
    if ($allow.ContainsKey($key)) { Fail "allowlist: doppelter Eintrag '$key'"; continue }
    $allow[$key] = [int]$e.count
}
foreach ($key in ($found.Keys | Sort-Object)) {
    $p = $key -split '\|', 2
    if (-not $allow.ContainsKey($key)) {
        Fail "NEUE feste Farbe in $($p[0]): '$($p[1])' ($($found[$key])x) -- var(--token) aus config/ui.tokens.json nutzen ODER mit Begruendung in scripts/build/ui_token_allowlist.json"
    } elseif ($allow[$key] -ne $found[$key]) {
        Fail "Anzahl '$($p[1])' in $($p[0]): gefunden $($found[$key]), Allowlist $($allow[$key]) -- count anpassen (nur schrumpfen)"
    }
}
foreach ($key in ($allow.Keys | Sort-Object)) {
    if (-not $found.ContainsKey($key)) { $p = $key -split '\|', 2; Fail "allowlist-ORPHAN in $($p[0]): '$($p[1])' -- nicht mehr vorhanden, Eintrag entfernen" }
}

# --- (5) Neue Flaechen ------------------------------------------------------------------------------------------
$uiExt = @(Get-UiFileExtensions)
foreach ($f in $tracked) {
    if ($uiExt -notcontains [System.IO.Path]::GetExtension($f).ToLowerInvariant()) { continue }
    if ((Test-UnderPrefix $f $scanRoots) -or (Test-UnderPrefix $f $excluded)) { continue }
    Fail "UI-Datei ausserhalb der registrierten Oberflaechen: $f -- in scripts/lib/ui_tokens.ps1 (Get-UiScanRoots, Get-UiSurfaces) eintragen und nach /ui-task vorgehen"
}

# --- (6) Bot-Profilbild -----------------------------------------------------------------------------------------
$bp = Get-UiBotProfilePaths
$bpStale = '.\scripts\dev\render_bot_profile.ps1 laufen lassen und Bild + Pruefwert mitcommitten'
$markAbs = Join-Path $RepoRoot $bp.Mark
$shaAbs = Join-Path (Join-Path $RepoRoot $bp.Dir) $bp.Sha
if ($tracked -notcontains "$($bp.Dir)/$($bp.Jpg)") { Fail "Bot-Profilbild fehlt: $($bp.Dir)/$($bp.Jpg) -- $bpStale" }
elseif (-not (Test-Path $markAbs)) { Fail "Bot-Profilbild: Zeichen fehlt: $($bp.Mark)" }
elseif (-not (Test-Path $shaAbs)) { Fail "Bot-Profilbild: Pruefwert fehlt ($($bp.Dir)/$($bp.Sha)) -- $bpStale" }
elseif ([System.IO.File]::ReadAllText($shaAbs, $u8).Trim() -cne (Get-UiTextSha256 (Get-UiBotProfileSvg $markAbs $tokens))) {
    Fail "Bot-Profilbild passt nicht mehr zu Zeichen oder Farbdatei -- $bpStale"
}

if ($fails -eq 0) { Write-Host "ui_token_lint: OK ($($pairs.Count) Kontrast-Paarungen je hell/dunkel, $($surfaces.Count) Block, $($scanFiles.Count) Dateien, $($found.Count) begruendete Altstellen)" -ForegroundColor Green }
else { Write-Host "ui_token_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
