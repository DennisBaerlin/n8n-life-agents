#Requires -Version 5.1
# render_app_intro.ps1 -- erzeugt die Erklaer-Animation der Ankuendigung „Uebersicht ist bereit“ je Katalogsprache:
# packages/core/build/stickers/app_intro_<sprache>.mp4 aus packages/core/build/stickers/app_intro.html
# (Headless-Chrome, sonst Edge; Muster render_stickers.ps1). Die MP4-Dateien (H.264, ohne Ton, 720 x 1120) sind committet; Telegram sendAnimation nimmt sie an.
# Knopf-Text = core.app.menu_button (dieselbe Quelle wie der echte Knopf), Titel = core.app.intro_title.
# -PreviewTitles: JSON-Datei {"<sprache>":"<Titel>"} fuer eine Vorschau, solange der Key noch nicht im Katalog steht.
# Prueft: MP4-Kopf (ftyp), avc1, Breite/Hoehe 720 x 1120, unter 2 MB (Telegram erlaubt 50 MB). Kein Netz, keine DB, kein Container.
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
$port = Get-Random -Minimum 58400 -Maximum 58499
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$input_ = [ordered]@{ scheme = 'dunkel'; sink = "http://127.0.0.1:$port/"; texts = $texts } | ConvertTo-Json -Depth 4 -Compress

$id = [guid]::NewGuid().ToString('N')
$profileDir = Join-Path $env:TEMP "lifeagents_intro_$id"
$url = 'file:///' + (Join-Path $dir 'app_intro.html').Replace('\', '/') + '#' + [Uri]::EscapeDataString($input_)
$chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$profileDir", $url)
$p = $null
try {
    $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -PassThru -WindowStyle Hidden
    $ctxTask = $listener.GetContextAsync()
    if (-not $ctxTask.Wait(180000)) { throw 'Headless-Rendern: keine Antwort der Seite nach 180 s.' }
    $req = $ctxTask.Result.Request
    $reader = [System.IO.StreamReader]::new($req.InputStream, $Utf8NoBom)
    $payload = $reader.ReadToEnd()
    $ctxTask.Result.Response.StatusCode = 204
    $ctxTask.Result.Response.Close()
} finally {
    $listener.Stop()
    if ($p -and -not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    Start-Sleep -Milliseconds 500
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $payload.StartsWith('{', [StringComparison]::Ordinal)) { throw "app_intro.html: $payload" }
$files = $payload | ConvertFrom-Json

$prefix = 'data:video/mp4;base64,'
foreach ($lang in $langs) {
    $uri = [string]$files.$lang
    if (-not $uri.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "$lang ist kein MP4." }
    $bytes = [Convert]::FromBase64String($uri.Substring($prefix.Length))
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($bytes.Length -lt 32 -or $ascii.Substring(4, 4) -ne 'ftyp') { throw "$lang hat keinen MP4-Kopf." }
    if ($ascii.IndexOf('avc1', [StringComparison]::Ordinal) -lt 0) { throw "$lang ist kein H.264-Video." }
    # tkhd: Breite als 16.16-Zahl 80 Byte nach dem Box-Namen.
    $ix = $ascii.IndexOf('tkhd', [StringComparison]::Ordinal) + 80
    $w = [int]$bytes[$ix] * 256 + $bytes[$ix + 1]
    if ($w -ne 720) { throw "$lang hat nicht die Breite 720 (gelesen: $w)." }
    if ($bytes.Length -ge 2MB) { throw "$lang ist zu gross: $($bytes.Length) Bytes." }
    [System.IO.File]::WriteAllBytes((Join-Path $dir "app_intro_$lang.mp4"), $bytes)
    Write-Host "  app_intro_$lang.mp4: $([Math]::Round($bytes.Length / 1KB)) KB" -ForegroundColor Green
}
