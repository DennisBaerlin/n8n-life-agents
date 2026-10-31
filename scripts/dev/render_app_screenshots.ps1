#Requires -Version 5.1
# render_app_screenshots.ps1 -- erzeugt die Beispielbilder der Mini-App fuer die Doku-Site
# (docs/site/static/img/app-uebersicht-{hell,dunkel}.png) aus der ECHTEN Seite packages/core/build/app/index.html mit
# dem echten Renderer (Get-UiRenderLibJs) und den Texten aus dem Katalog (packages/*/locales/de.json). Anlass
# (Uebersicht R3, 2026-10-28): die Bilder waren von Hand gemacht und zeigten nach einer Text-Aenderung die alte
# Ueberschrift -> jetzt reproduzierbar, nach jeder sichtbaren Aenderung am Bildschirm Vermoegen neu laufen lassen.
#
# Statt des Servers liefert ein fetch-Stub EIN festes View-Modell (Bildschirm Vermoegen, Form wie
# finance.fn_app_screen_overview) mit ERFUNDENEN Werten (Repo oeffentlich, nie echte Daten); das Telegram-Skript
# entfaellt. Die Kinder-Zeile wird aufgeklappt (zeigt das Aufklappen). Aufnahme per Headless-Chrome (sonst Edge),
# 390 CSS-px breit, Faktor 2, hell und dunkel (--force-dark-mode). Kein Netz, keine DB, kein Container.
#   .\scripts\dev\render_app_screenshots.ps1
# Danach: .\scripts\build_site.ps1
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts\build\lib\build_helpers.ps1')

$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Kein Chrome/Edge gefunden (Headless-Aufnahme).' }

# Texte aus dem Katalog (eine Adresse): nur die Keys, die das View-Modell unten nutzt
$cat = @{}
foreach ($f in 'packages\core\locales\de.json', 'packages\finance\locales\de.json') {
    $j = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $f), $Utf8NoBom) | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $cat[$p.Name] = $p.Value }
}
$keys = 'core.app.title', 'core.app.gap', 'core.app.sum', 'core.app.all_good', 'core.fmt.empty', 'finance.app.screen.overview',
        'finance.app.overview.title', 'finance.app.overview.hero', 'finance.app.overview.hero_note', 'finance.app.overview.section_liquid',
        'finance.app.overview.section_bound', 'finance.app.overview.section_debts', 'finance.app.overview.section_kids',
        'finance.app.overview.share', 'finance.app.overview.empty', 'finance.enum.asset_bucket.cash', 'finance.enum.asset_bucket.p2p',
        'finance.enum.asset_bucket.depot', 'finance.enum.asset_bucket.real_estate', 'finance.enum.asset_bucket.loan'
$t = [ordered]@{}
foreach ($k in $keys) {
    if (-not $cat.ContainsKey($k)) { throw "Text-Key fehlt im Katalog: $k" }
    $t[$k] = $cat[$k]
}

function Tpl([string]$Key, $Params = @{}) { [ordered]@{ kind = 'tpl'; value = $Key; params = $Params } }
function Money([decimal]$V) { [ordered]@{ kind = 'money'; value = $V; currency = 'EUR' } }
function Bucket([string]$B) { [ordered]@{ kind = 'enum'; enum = 'finance.enum.asset_bucket'; value = $B } }
function Share([decimal]$Pct) { Tpl 'finance.app.overview.share' ([ordered]@{ pct = [ordered]@{ kind = 'number'; value = $Pct; digits = 1 } }) }
function New-AppItem($Label, $Sub, $Value, $Progress = $null, $Details = $null, $Target = $null) {
    $i = [ordered]@{ label = $Label; sub = $Sub; value = $Value; gap = $false; pill = $null; progress = $Progress; target = $Target }
    if ($Details) { $i['details'] = $Details }
    $i
}

# Erfundene Werte (Form wie finance.fn_app_screen_overview, UX-Gesamtkonzept 2026-10-31): Besitz 373.250,37
# (schnell verfuegbar 53.250,37 aus 3 Zeilen -> „zusammen“, gebunden 320.000 aus 1 Zeile -> keine Summe), Schulden
# 180.000 positiv ohne Summe, Hero = Besitz - Schulden = 193.250,37; Kind separat, aufgeklappt
$empty = Tpl 'finance.app.overview.empty'
$liquid = @(
    (New-AppItem (Bucket 'cash') (Share 3.3) (Money 12250.37) ([ordered]@{ pct = 3.3; state = 'neutral' })),
    (New-AppItem (Bucket 'p2p') (Share 1.3) (Money 5000.00) ([ordered]@{ pct = 1.3; state = 'neutral' })),
    (New-AppItem (Bucket 'depot') (Share 9.6) (Money 36000.00) ([ordered]@{ pct = 9.6; state = 'neutral' }))
)
$bound = @(, (New-AppItem (Bucket 'real_estate') (Share 85.7) (Money 320000.00) ([ordered]@{ pct = 85.7; state = 'neutral' })))
$debts = @(, (New-AppItem (Bucket 'loan') $null (Money 180000.00) $null $null ([ordered]@{ screen = 'loans'; params = @{} })))
$kidDetails = @(
    [ordered]@{ label = (Bucket 'cash'); value = (Money 300.00) },
    [ordered]@{ label = (Bucket 'depot'); value = (Money 1000.00) }
)
$kids = @(, (New-AppItem 'Kind Beispiel' $null (Money 1300.00) $null $kidDetails))
$view = [ordered]@{
    ok       = $true
    title    = (Tpl 'finance.app.overview.title')
    hero     = [ordered]@{ label = (Tpl 'finance.app.overview.hero'); value = (Money 193250.37); gap = $false
                           note = (Tpl 'finance.app.overview.hero_note' ([ordered]@{ assets = (Money 373250.37); debts = (Money 180000.00) })) }
    banners  = @(, [ordered]@{ state = 'ok'; icon = 'check'; text = (Tpl 'core.app.all_good'); target = $null })   # das eine gruene Signal (core.fn_app_nav)
    sections = @(
        [ordered]@{ title = (Tpl 'finance.app.overview.section_liquid'); value = (Money 53250.37); empty = $empty; items = $liquid },
        [ordered]@{ title = (Tpl 'finance.app.overview.section_bound'); value = $null; empty = $empty; items = $bound },
        [ordered]@{ title = (Tpl 'finance.app.overview.section_debts'); value = $null; empty = $empty; items = $debts },
        [ordered]@{ title = (Tpl 'finance.app.overview.section_kids'); value = $null; empty = $empty; items = $kids }
    )
}
$nav = [ordered]@{
    ok = $true
    # Datums-Kurzform wie core.fn_app_screen (Fenster [heute - 3 Monate, heute + 9 Monate)), sonst zeigte das Bild Jahre,
    # die die App nicht zeigt
    ui = [ordered]@{ lang = 'de'; locale = 'de-DE'; t = $t
                     date_short = [ordered]@{ from = (Get-Date).AddMonths(-3).ToString('yyyy-MM-dd'); to = (Get-Date).AddMonths(9).ToString('yyyy-MM-dd') } }
    screens = @([ordered]@{ screen = 'overview'; title = (Tpl 'finance.app.screen.overview'); icon = '💶' })
    first = [ordered]@{ screen = 'overview'; view = $view }
}
$json = $nav | ConvertTo-Json -Depth 30 -Compress

# Seite wie im Build (core.main_app_serve) + fetch-Stub statt Server, ohne Telegram-Skript, Kinder-Zeile aufklappen
$html = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\build\app\index.html'), $Utf8NoBom)
$html = $html.Replace('/*__UI_RENDER_LIB__*/', (Get-UiRenderLibJs))
$html = [regex]::Replace($html, '<script src="https://telegram\.org/[^"]*"></script>', '')
# Headless-Chrome hat eine Mindest-Fensterbreite (~500 px): die Seite wird per CSS auf Handybreite (390 px) gesetzt und
# das Bild danach auf 780 x 1520 px (Faktor 2) zugeschnitten. Hell/Dunkel fest ueber Telegrams colorScheme (data-scheme)
# statt ueber die Windows-Einstellung; Dunkel braucht zusaetzlich prefers-color-scheme (--force-dark-mode).
$W = 390; $H = 790
Add-Type -AssemblyName System.Drawing
$imgDir = Join-Path $RepoRoot 'docs\site\static\img'
foreach ($shot in @(@{ Name = 'app-uebersicht-hell.png'; Scheme = 'light' }, @{ Name = 'app-uebersicht-dunkel.png'; Scheme = 'dark' })) {
    $stub = "<style>body { width: ${W}px; } * { transition: none !important; }</style><script>window.Telegram = { WebApp: { colorScheme: '$($shot.Scheme)', initData: '' } };" +
            "window.fetch = function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve($json); } }); };" +
            "window.addEventListener('load', function () { setTimeout(function () { var b = document.querySelector('.toggle'); if (b) b.click(); }, 200); });</script>"
    $page = $html.Replace('<main id="app"', "$stub`n<main id=""app""")
    $tmp = Join-Path $env:TEMP 'lifeagents_app_screenshot.html'
    [System.IO.File]::WriteAllText($tmp, $page, $Utf8NoBom)
    $raw = Join-Path $env:TEMP 'lifeagents_app_screenshot_raw.png'
    $profileDir = Join-Path $env:TEMP ('lifeagents_shot_' + [guid]::NewGuid().ToString('N'))
    $chromeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=$profileDir",
                    '--force-device-scale-factor=2', "--window-size=600,$H", '--virtual-time-budget=3000', "--screenshot=$raw")
    if ($shot.Scheme -eq 'dark') { $chromeArgs += '--force-dark-mode' }
    $chromeArgs += ('file:///' + $tmp.Replace('\', '/'))
    $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -or -not (Test-Path $raw)) { throw "Aufnahme fehlgeschlagen: $($shot.Name) (Exit $($p.ExitCode))" }
    $src = [System.Drawing.Image]::FromFile($raw)
    try {
        $dst = $src.Clone([System.Drawing.Rectangle]::new(0, 0, 2 * $W, [Math]::Min(2 * $H, $src.Height)), $src.PixelFormat)
        $out = Join-Path $imgDir $shot.Name
        $dst.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()
    } finally { $src.Dispose() }
    Remove-Item $raw, $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] $out" -ForegroundColor Green
}
Write-Host 'Fertig. Danach: .\scripts\build_site.ps1' -ForegroundColor Cyan
