#Requires -Version 5.1
# render_stickers.ps1 -- erzeugt die Persona-Sticker packages/core/build/stickers/<code>_<ausdruck>.webp (512 x 512 px)
# aus der Quelle packages/core/build/stickers/stickers.js (Bot mit Gesicht, 2026-10-30). Die WebP-Dateien sind
# committet: der Release-Tarball bringt sie nach /usr/local/lib/lifeagents/packages/core/build/stickers/, der lokale
# Gateway (provisioning/llm_gateway, Route /__telegram/sendSticker) laedt sie von dort hoch.
# Nach jeder Aenderung an stickers.js neu laufen lassen und die Dateien mit-committen.
#
# Weg: Headless-Chrome (sonst Edge, Analog render_app_screenshots.ps1) oeffnet render.html, das jedes SVG auf ein
# Canvas zeichnet und als WebP in den DOM schreibt (--dump-dom). Kein Netz, keine DB, kein Container.
# Prueft: jede Persona aus dem Core-Manifest (personas.list) hat ein Set; jede Datei ist ein WebP.
#   .\scripts\dev\render_stickers.ps1
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$dir = Join-Path $RepoRoot 'packages\core\build\stickers'
$expressions = @('hallo', 'top', 'hmm', 'yay')

$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Kein Chrome/Edge gefunden (Headless-Rendern).' }

$manifest = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json
$codes = @($manifest.personas.list | ForEach-Object { $_.code })

$profileDir = Join-Path $env:TEMP ('lifeagents_stickers_' + [guid]::NewGuid().ToString('N'))
$dom = Join-Path $env:TEMP ('lifeagents_stickers_' + [guid]::NewGuid().ToString('N') + '.html')
$chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$profileDir", '--allow-file-access-from-files',
                '--virtual-time-budget=10000', '--dump-dom', ('file:///' + (Join-Path $dir 'render.html').Replace('\', '/')))
try {
    $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if ($p.ExitCode -ne 0) { throw "Headless-Rendern fehlgeschlagen (Exit $($p.ExitCode))" }
    $html = [System.IO.File]::ReadAllText($dom, $Utf8NoBom)
} finally {
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $dom -Force -ErrorAction SilentlyContinue
}
$m = [regex]::Match($html, '<pre id="out">(.*?)</pre>', 'Singleline')
if (-not $m.Success) { throw 'render.html lieferte kein Ergebnis (#out fehlt).' }
$payload = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
if (-not $payload.StartsWith('{', [StringComparison]::Ordinal)) { throw "render.html: $payload" }
$files = $payload | ConvertFrom-Json

foreach ($code in $codes) {
    foreach ($ex in $expressions) {
        $name = "${code}_$ex"
        $uri = $files.$name
        if (-not $uri) { throw "Sticker fehlt in stickers.js: $name (Persona aus dem Core-Manifest)" }
        if (-not $uri.StartsWith('data:image/webp;base64,', [StringComparison]::Ordinal)) { throw "$name ist kein WebP (Browser ohne WebP-Encoder?)" }
        $bytes = [Convert]::FromBase64String($uri.Substring('data:image/webp;base64,'.Length))
        $out = Join-Path $dir "$name.webp"
        [System.IO.File]::WriteAllBytes($out, $bytes)
        if ($Verbose) { Write-Host "  [OK] $name.webp ($([Math]::Round($bytes.Length / 1KB, 1)) KB)" -ForegroundColor Green }
    }
}
Write-Host "Fertig: $($codes.Count * $expressions.Count) Sticker in packages\core\build\stickers\" -ForegroundColor Cyan
