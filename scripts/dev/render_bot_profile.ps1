#Requires -Version 5.1
# render_bot_profile.ps1 -- erzeugt das Telegram-Profilbild des Bots packages/core/build/bot_profile/bot_profile.jpg (640 x 640 px)
# aus dem einen Zeichen des Projekts (docs/site/layouts/partials/mark.html) und der Farbdatei (config/ui.tokens.json).
# Das JPG ist committet: der Release-Tarball enthaelt nur provisioning/ und packages/, das Zielsystem hat keinen Browser.
# Der Installer laedt es hoch (provisioning/lib/bootstrap_owner.sh _ensure_bot_profile_photo), wenn der Bot noch kein Bild hat.
# Nach jeder Aenderung am Zeichen oder an den Farben neu laufen lassen und Bild + Pruefwert (source.sha256) mit-committen;
# scripts/ui_token_lint.ps1 (6) schlaegt sonst an.
#
# Weg: Headless-Chrome (sonst Edge, Analog render_stickers.ps1) zeichnet das SVG auf ein Canvas und schreibt es als JPEG in den
# DOM (--dump-dom). Kein Netz, keine DB, kein Container. Telegram nimmt fuer statische Profilbilder nur JPG an (Bot API,
# InputProfilePhotoStatic).
# Maße und JPEG-Kopf des committeten Bildes prueft scripts/dev/bot_profile_photo_test.ps1.
#   .\scripts\dev\render_bot_profile.ps1 [-MarkFile <pfad>] [-OutDir <ordner>]   (Optionen nur fuer eine Vorschau: anderes Zeichen, anderer Zielordner)
param([string]$MarkFile, [string]$OutDir, [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path (Join-Path $PSScriptRoot '..') 'lib\ui_tokens.ps1')
$paths = Get-UiBotProfilePaths
if (-not $MarkFile) { $MarkFile = Join-Path $RepoRoot $paths.Mark }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot $paths.Dir }
if (-not (Test-Path $MarkFile)) { throw "Zeichen fehlt: $MarkFile" }
$svg = Get-UiBotProfileSvg $MarkFile (Read-UiTokens $RepoRoot)

$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
             "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Kein Chrome/Edge gefunden (Headless-Rendern).' }

$svgJson = $svg | ConvertTo-Json -Compress
$page = @"
<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><pre id="out">pending</pre><script>
var img = new Image();
img.onload = function () {
  var c = document.createElement('canvas');
  c.width = img.width; c.height = img.height;
  c.getContext('2d').drawImage(img, 0, 0);
  document.getElementById('out').textContent = c.toDataURL('image/jpeg', 0.92);
};
img.onerror = function () { document.getElementById('out').textContent = 'ERROR svg'; };
img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent($svgJson);
</script></body></html>
"@

$work = Join-Path $env:TEMP ('lifeagents_bot_profile_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$html = Join-Path $work 'render.html'
$dom = Join-Path $work 'dom.html'
[System.IO.File]::WriteAllText($html, $page, $Utf8NoBom)
$chromeArgs = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$(Join-Path $work 'profile')", '--allow-file-access-from-files',
                '--virtual-time-budget=10000', '--dump-dom', ('file:///' + $html.Replace('\', '/')))
try {
    $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if ($p.ExitCode -ne 0) { throw "Headless-Rendern fehlgeschlagen (Exit $($p.ExitCode))" }
    $out = [System.IO.File]::ReadAllText($dom, $Utf8NoBom)
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
$m = [regex]::Match($out, '<pre id="out">(.*?)</pre>', 'Singleline')
if (-not $m.Success) { throw 'Render-Seite lieferte kein Ergebnis (#out fehlt).' }
$prefix = 'data:image/jpeg;base64,'
if (-not $m.Groups[1].Value.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "Kein JPEG erzeugt: $($m.Groups[1].Value)" }
$bytes = [Convert]::FromBase64String($m.Groups[1].Value.Substring($prefix.Length))

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
[System.IO.File]::WriteAllBytes((Join-Path $OutDir $paths.Jpg), $bytes)
[System.IO.File]::WriteAllText((Join-Path $OutDir $paths.Sha), (Get-UiTextSha256 $svg) + "`n", $Utf8NoBom)
if ($Verbose) { Write-Host "  SVG: $svg" -ForegroundColor DarkGray }
Write-Host "Fertig: $(Join-Path $OutDir $paths.Jpg) ($([Math]::Round($bytes.Length / 1KB, 1)) KB)" -ForegroundColor Cyan
