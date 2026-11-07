#Requires -Version 5.1
# serve_art_preview.ps1 -- Vorschau der Erklär-Bilder (Quellen config/ui.art.*.svg, Generator scripts/lib/ui_art.ps1) im Browser
# der Claude-Desktop-App (Vorschau-Eintrag "explain-art" in .claude/launch.json). Erzeugt bei jeder Anfrage neu aus den Quellen,
# in ALLEN Sprachen und hell/dunkel (auch Kombinationen, die kein Verbraucher bekommt), schmale Wizard-Fassungen als *.compact.svg;
# schreibt nichts ins Repo.
#   .\scripts\dev\serve_art_preview.ps1 [-Port 8790]
#   http://localhost:8790/?lang=de&theme=dark          Galerie (lang: de|en|ko|all, theme: light|dark)
#   http://localhost:8790/?lang=de&t=4.5               alle Bilder bei Sekunde 4.5 angehalten (Aufnahmen je Szene)
#   http://localhost:8790/svg/reach-tunnel.de.light.svg  ein Bild
# Strg+C (bzw. Stoppen der Vorschau) beendet den Server. Nur localhost.
param([int]$Port = 8790)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path (Join-Path (Join-Path $RepoRoot 'scripts') 'lib') 'ui_tokens.ps1')
. (Join-Path (Join-Path (Join-Path $RepoRoot 'scripts') 'lib') 'ui_art.ps1')
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-PreviewSvgs {
    $tokens = Read-UiTokens $RepoRoot
    $script:UiArtRepoRoot = $RepoRoot
    $markPaths = @(Get-UiMarkPaths $RepoRoot)
    $cat = @{}
    foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages/core/locales') -Filter '*.json')) { $cat[$f.BaseName] = [System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom) | ConvertFrom-Json }
    $map = [ordered]@{}
    foreach ($a in (Get-UiArts)) {
        $srcPath = Get-UiArtSourcePath $a.Name
        if (-not (Test-Path (Join-Path $RepoRoot $srcPath))) { continue }   # Bild in Arbeit
        $src = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $srcPath), $Utf8NoBom).Replace("`r`n", "`n")
        foreach ($lang in 'de', 'en', 'ko') { foreach ($theme in 'light', 'dark') { foreach ($v in $a.Variants) {
                    $map[(Get-UiArtFileName $a.Name $v $lang $theme)] = ConvertTo-UiArtSvg $src $v $cat[$lang] $lang $theme $tokens $markPaths $srcPath
                    if (@($a.Targets | Where-Object { $_.Compact }).Count -gt 0) { $map[(Get-UiArtFileName $a.Name $v $lang $theme) -replace '\.svg$', '.compact.svg'] = ConvertTo-UiArtSvg $src $v $cat[$lang] $lang $theme $tokens $markPaths $srcPath $true }
                } } }
    }
    $map
}

# Galerie: <object> statt <img>, damit ?t= die Animationen im Bild-Dokument anhalten kann (bei <img> nicht erreichbar).
function Get-Gallery([string]$Lang, [string]$Theme, [string]$T) {
    $bg = if ($Theme -eq 'dark') { '#12181D' } else { '#FFFFFF' }
    $fg = if ($Theme -eq 'dark') { '#A2B1BC' } else { '#55636E' }
    $names = @((Get-PreviewSvgs).Keys | Where-Object { $_ -like "*.$Theme*.svg" -and ($Lang -eq 'all' -or $_ -like "*.$Lang.$Theme*.svg") })
    $items = ($names | ForEach-Object { "<p>$_</p><object type=`"image/svg+xml`" data=`"/svg/$_`"></object>" }) -join "`n"
    $freeze = if ($T) { "<script>const t=$([double]::Parse($T, [Globalization.CultureInfo]::InvariantCulture))*1000;document.querySelectorAll('object').forEach(o=>o.addEventListener('load',()=>{o.contentDocument.getAnimations().forEach(a=>{a.pause();a.currentTime=t;});}));</script>" } else { '' }
    "<!doctype html><html><head><meta charset=`"utf-8`"><title>Erklär-Bilder</title><style>body{margin:0;padding:16px;background:$bg;color:$fg;font:13px system-ui,sans-serif} object{display:block;width:720px;margin:4px 0 18px} p{margin:0}</style></head><body>$items$freeze</body></html>"
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Erklär-Bilder-Vorschau: http://localhost:$Port/?lang=de&theme=light  (t=Sekunde hält an). Strg+C beendet." -ForegroundColor Cyan
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response
        $isHead = $ctx.Request.HttpMethod -eq 'HEAD'   # Port-Check der Desktop-App: Header ohne Body
        try {
            $p = $ctx.Request.Url.AbsolutePath
            $q = $ctx.Request.QueryString
            if ($p -eq '/') {
                $lang = if ($q['lang']) { $q['lang'] } else { 'de' }
                $theme = if ($q['theme'] -eq 'dark') { 'dark' } else { 'light' }
                $bytes = $Utf8NoBom.GetBytes((Get-Gallery $lang $theme $q['t']))
                $type = 'text/html; charset=utf-8'
            } elseif ($p.StartsWith('/svg/')) {
                $svgs = Get-PreviewSvgs
                $name = $p.Substring(5)
                if (-not $svgs.Contains($name)) { $res.StatusCode = 404; continue }
                $bytes = $Utf8NoBom.GetBytes($svgs[$name])
                $type = 'image/svg+xml; charset=utf-8'
            } else {
                $res.StatusCode = 404
                continue
            }
            $res.ContentType = $type
            $res.Headers['Cache-Control'] = 'no-store'
            $res.ContentLength64 = $bytes.Length
            if (-not $isHead) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
        } catch {
            Write-Host "  [FEHLER] $($_.Exception.Message)" -ForegroundColor Red
            try { $res.StatusCode = 500 } catch { }
        } finally {
            try { $res.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
}
