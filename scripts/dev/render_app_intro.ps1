#Requires -Version 5.1
# render_app_intro.ps1 -- erzeugt die Erklaer-Animation der Ankuendigung „Uebersicht ist bereit“ je Katalogsprache:
# packages/core/build/stickers/app_intro_<sprache>.gif aus packages/core/build/stickers/app_intro.html
# (Headless-Chrome, sonst Edge; Muster render_stickers.ps1). Die GIF-Dateien sind committet; Telegram sendAnimation nimmt sie an.
# Knopf-Text = core.app.menu_button (dieselbe Quelle wie der echte Knopf), Titel = core.app.intro_title.
# -PreviewTitles: JSON-Datei {"<sprache>":"<Titel>"} fuer eine Vorschau, solange der Key noch nicht im Katalog steht.
# Prueft: GIF89a, 360 x 560, unter 2 MB (Telegram erlaubt 50 MB). Kein Netz, keine DB, kein Container.
#   .\scripts\dev\render_app_intro.ps1 [-PreviewTitles .local\titel.json]
# Exit 0, sonst Abbruch mit Grund.
param([string]$PreviewTitles)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$dir = Join-Path $RepoRoot 'packages\core\build\stickers'

$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Kein Chrome/Edge gefunden (Headless-Rendern).' }

$manifest = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json
$langs = @($manifest.languages.list | ForEach-Object { [string]$_.code })
$override = $null
if ($PreviewTitles) { $override = [System.IO.File]::ReadAllText((Resolve-Path $PreviewTitles).Path, $Utf8NoBom) | ConvertFrom-Json }

$texts = [ordered]@{}
foreach ($lang in $langs) {
    $loc = [System.IO.File]::ReadAllText((Join-Path $RepoRoot "packages\core\locales\$lang.json"), $Utf8NoBom) | ConvertFrom-Json
    $title = if ($override) { [string]$override.$lang } else { [string]$loc.'core.app.intro_title' }
    if (-not $title) { throw "Titel fehlt fuer '$lang' (core.app.intro_title)." }
    $btn = [string]$loc.'core.app.menu_button'
    if (-not $btn) { throw "core.app.menu_button fehlt fuer '$lang'." }
    $texts[$lang] = [ordered]@{ btn = $btn; title = $title }
}
$input_ = [ordered]@{ scheme = 'dunkel'; texts = $texts } | ConvertTo-Json -Depth 4 -Compress

$id = [guid]::NewGuid().ToString('N')
$profileDir = Join-Path $env:TEMP "lifeagents_intro_$id"
$dom = Join-Path $env:TEMP "lifeagents_intro_$id.html"
$url = 'file:///' + (Join-Path $dir 'app_intro.html').Replace('\', '/') + '#' + [Uri]::EscapeDataString($input_)
$chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$profileDir", '--virtual-time-budget=90000', '--dump-dom', $url)
try {
    $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom -RedirectStandardError "$dom.err"
    if ($p.ExitCode -ne 0) { throw "Headless-Rendern fehlgeschlagen (Exit $($p.ExitCode))" }
    $html = [System.IO.File]::ReadAllText($dom, $Utf8NoBom)
} finally {
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $dom, "$dom.err" -Force -ErrorAction SilentlyContinue
}
$m = [regex]::Match($html, '<pre id="out">(.*?)</pre>', 'Singleline')
if (-not $m.Success) { throw 'app_intro.html lieferte kein Ergebnis (#out fehlt).' }
$payload = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
if (-not $payload.StartsWith('{', [StringComparison]::Ordinal)) { throw "app_intro.html: $payload" }
$files = $payload | ConvertFrom-Json

$prefix = 'data:image/gif;base64,'
foreach ($lang in $langs) {
    $uri = [string]$files.$lang
    if (-not $uri.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "$lang ist kein GIF." }
    $bytes = [Convert]::FromBase64String($uri.Substring($prefix.Length))
    if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 6) -ne 'GIF89a') { throw "$lang hat keinen GIF-Kopf." }
    if ([BitConverter]::ToUInt16($bytes, 6) -ne 360 -or [BitConverter]::ToUInt16($bytes, 8) -ne 560) { throw "$lang hat nicht 360 x 560." }
    if ($bytes.Length -ge 2MB) { throw "$lang ist zu gross: $($bytes.Length) Bytes." }
    [System.IO.File]::WriteAllBytes((Join-Path $dir "app_intro_$lang.gif"), $bytes)
    Write-Host "  app_intro_$lang.gif: $([Math]::Round($bytes.Length / 1KB)) KB" -ForegroundColor Green
}
