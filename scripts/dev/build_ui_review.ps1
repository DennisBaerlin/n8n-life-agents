#Requires -Version 5.1
# build_ui_review.ps1 -- Aufnahme einer Oberflaechen-Aenderung fuer die Freigabe des Owners (Skill /ui-task): Bilder in
# Handybreite, hell und dunkel, vorher und nachher (fuer Chat und Pruef-Agent). Mit -Page zusaetzlich EINE Seite ohne Server,
# die eine Session als privates Artefakt veroeffentlicht, wenn der Owner am Handy ist und localhost nicht sieht (Reserve; das
# Markieren dort ist ungeprueft). Am Rechner markiert der Owner direkt im Browser-Bereich. Nur erfundene Werte: die Mini-App kommt
# aus scripts/dev/lib/app_preview_data.json, die Doku-Seite aus ihrem gebauten Output. Alles liegt unter .local/ (nicht im Repo).
#   .\scripts\dev\build_ui_review.ps1 -Name kurzer-hinweis -Capture vorher      vor der Aenderung, alle Reiter
#   .\scripts\dev\build_ui_review.ps1 -Name kurzer-hinweis -Capture nachher     nach der Aenderung
#   .\scripts\dev\build_ui_review.ps1 -Name kurzer-hinweis -Page                baut .local/ui_review/<Name>/index.html
#   -Capture ... -Surface site -Pages index.html,docs/erste-schritte.html       Doku-Seite (vorher .\scripts\build_site.ps1), nur hell
#   -Capture ... -Surface desktop                                               Start-App: alle Faelle aus preview/mock.js, 600 px
#   -Screens overview,accounts                                                  nur diese Reiter (Standard: alle aus dem Datenmodell)
#   -Title 'Hinweis kuerzer'                                                    Ueberschrift der Seite
# Der Pruef-Agent (.claude/agents/ui-review.md) liest den Ordner nachher/. Kein Netz, keine DB, kein Container.
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name,
    [ValidateSet('mini-app', 'site', 'desktop')][string]$Surface = 'mini-app',
    [ValidateSet('vorher', 'nachher')][string]$Capture = '',
    [string[]]$Screens = @(),
    [string[]]$Pages = @('index.html'),
    [switch]$Page,
    [string]$Title = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Capture -and -not $Page) { throw 'Bitte -Capture vorher|nachher und/oder -Page angeben.' }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts\build\lib\build_helpers.ps1')
. (Join-Path $PSScriptRoot 'lib\app_preview.ps1')
. (Join-Path $PSScriptRoot 'lib\headless_shot.ps1')
. (Join-Path $RepoRoot 'scripts\lib\ui_tokens.ps1')

$Root = Join-Path $RepoRoot ".local\ui_review\$Name"
$PhoneW = 375; $MaxH = 4000; $Scale = 1.5

# Doku-Seiten duerfen laenger sein als das Bild (Layout-Pruefung, der ganze Text steht in der .txt); ein Reiter der Mini-App nie
function Save-Shot([string]$Html, [string]$Base, [string]$Scheme) {
    $tmp = "$Base.$Scheme.tmp.html"
    [System.IO.File]::WriteAllText($tmp, $Html, $Utf8NoBom)
    Invoke-HeadlessShot -File $tmp -Out "$Base-$Scheme.png" -WidthPx $PhoneW -HeightPx $MaxH -Scale $Scale -Dark:($Scheme -eq 'dark') -TrimBottom -AllowCut:($Surface -eq 'site')
    Remove-Item $tmp -Force
}

if ($Capture) {
    $dir = Join-Path $Root $Capture
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Root 'surface.txt'), $Surface, $Utf8NoBom)   # -Page liest es, kein zweites Angeben
    if ($Surface -eq 'mini-app') {
        $all = @((Get-AppPreviewDataText | ConvertFrom-Json).screens | ForEach-Object { $_.screen })
        $list = if ($Screens.Count) { $Screens } else { $all }
        foreach ($s in $list) {
            foreach ($scheme in 'light', 'dark') {
                Save-Shot (Get-AppPreviewPage -Scheme $scheme -Width $PhoneW -NoTransitions -Screen $s -FullHeight) (Join-Path $dir $s) $scheme
            }
            $tmp = Join-Path $dir "$s.tmp.html"
            [System.IO.File]::WriteAllText($tmp, (Get-AppPreviewPage -Scheme 'light' -Width $PhoneW -NoTransitions -Screen $s), $Utf8NoBom)
            [System.IO.File]::WriteAllText((Join-Path $dir "$s.txt"), (Get-HeadlessText -File $tmp), $Utf8NoBom)
            Remove-Item $tmp -Force
            Write-Host "  [OK] $Capture/$s" -ForegroundColor Green
        }
    } elseif ($Surface -eq 'desktop') {
        # Start-App: echte ui/-Dateien mit der Vorschau-Attrappe, je Fall ein Bildschirm (Name:Fall:Bildschirm[:win]).
        $ui = Join-Path $RepoRoot 'provisioning\desktop\ui'
        $mock = Join-Path $RepoRoot 'provisioning\desktop\preview\mock.js'
        $url = { param($p) 'file:///' + $p.Replace('\', '/') }
        $cases = @('welcome:missing:welcome', 'need:missing:need', 'sys-hint:hints:sys', 'sys-stop:blocked:sys', 'move:dmg:move', 'resume:interrupted:resume',
            'dk-missing:missing:docker', 'dk-stopped:stopped:docker', 'dk-ready:ready:docker', 'dk-orbstack:ready-orbstack:docker', 'dk-old:old:docker',
            'dk-memory:memory:docker', 'dk-other:other:docker', 'dk-help:colima:docker', 'dk-remote:remote:docker', 'wizard-missing:missing:wizardMissing',
            'power-laptop:laptop:power', 'power-result:missing:powerApply', 'done:missing:finish', 'home:complete:home', 'report:missing:report',
            'uninstall:missing:uninstall', 'power-restore:missing:powerRestore', 'win-sys:hints:sys:win', 'win-power:missing:power:win')
        if ($Screens.Count) { $cases = @($cases | Where-Object { $Screens -contains ($_ -split ':')[0] }) }
        foreach ($c in $cases) {
            $n, $fall, $screen, $os = $c -split ':'
            $params = "state=$fall&screen=$screen" + $(if ($os) { "&os=$os" } else { '' })
            $html = [System.IO.File]::ReadAllText((Join-Path $ui 'index.html'), $Utf8NoBom)
            $html = $html.Replace('href="app.css"', "href=`"$(& $url (Join-Path $ui 'app.css'))`"")
            $html = $html.Replace('<script src="app.js"></script>', "<script>window.__previewParams = '$params';</script><script src=`"$(& $url $mock)`"></script><script src=`"$(& $url (Join-Path $ui 'app.js'))`"></script>")
            # Fensterhoehe der App ist fest, die Aufnahme zeigt den ganzen Inhalt samt Knopfleiste darunter; Hell/Dunkel
            # ueber data-theme, weil Headless-Chrome sonst der Einstellung von Windows folgt.
            $html = $html.Replace('</head>', '<style>html,body{height:auto}main{overflow:visible;flex:none}.nav{border-bottom:1px solid var(--hairline)}</style></head>')
            foreach ($scheme in 'light', 'dark') {
                $tmp = Join-Path $dir "$n.$scheme.tmp.html"
                [System.IO.File]::WriteAllText($tmp, $html.Replace('<html lang="de">', "<html lang=`"de`" data-theme=`"$scheme`">"), $Utf8NoBom)
                Invoke-HeadlessShot -File $tmp -Out (Join-Path $dir "$n-$scheme.png") -WidthPx 600 -HeightPx 900 -Scale 1.25 -Dark:($scheme -eq 'dark') -TrimBottom -AllowCut
                if ($scheme -eq 'light') { [System.IO.File]::WriteAllText((Join-Path $dir "$n.txt"), (Get-HeadlessText -File $tmp), $Utf8NoBom) }
                Remove-Item $tmp -Force
            }
            Write-Host "  [OK] $Capture/$n" -ForegroundColor Green
        }
    } else {
        foreach ($p in $Pages) {
            $src = Join-Path $RepoRoot ("docs\site\public\" + $p.Replace('/', '\'))
            if (-not (Test-Path $src)) { throw "Seite fehlt: $src (erst .\scripts\build_site.ps1)" }
            $slug = ($p -replace '\.html$', '') -replace '[^a-zA-Z0-9-]', '-'
            $srcUrl = 'file:///' + (Resolve-Path $src).Path.Replace('\', '/')
            Save-Shot "<!doctype html><body style='margin:0'><iframe src='$srcUrl' style='border:0;width:${PhoneW}px;height:${MaxH}px'></iframe></body>" (Join-Path $dir $slug) 'light'
            [System.IO.File]::WriteAllText((Join-Path $dir "$slug.txt"), (Get-HeadlessText -File (Resolve-Path $src).Path), $Utf8NoBom)
            Write-Host "  [OK] $Capture/$slug" -ForegroundColor Green
        }
    }
}

if ($Page) {
    $surfaceFile = Join-Path $Root 'surface.txt'
    if (-not (Test-Path $surfaceFile)) { throw "Keine Aufnahme unter $Root (erst -Capture)." }
    $Surface = [System.IO.File]::ReadAllText($surfaceFile, $Utf8NoBom)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode($t) }
    # Ueberschrift = Titel des Reiters aus dem Katalog, nicht der interne Name
    $titles = @{}
    $order = @()
    if ($Surface -eq 'mini-app') {
        $texts = Get-AppPreviewTexts
        foreach ($s in (Get-AppPreviewDataText | ConvertFrom-Json).screens) { $titles[$s.screen] = [string]$texts[[string]$s.title.value]; $order += $s.screen }
    }
    $tokens = Read-UiTokens $RepoRoot
    $states = @('vorher', 'nachher') | Where-Object { Test-Path (Join-Path $Root $_) }
    $keys = @($states | ForEach-Object { Get-ChildItem (Join-Path $Root $_) -Filter '*.png' } | ForEach-Object { $_.BaseName -replace '-(light|dark)$', '' } | Select-Object -Unique)
    if ($keys.Count -eq 0) { throw "Keine Bilder unter $Root." }
    if ($order.Count) { $keys = @($keys | Sort-Object { [array]::IndexOf($order, $_) }) }   # Reihenfolge wie in der App
    $sections = foreach ($k in $keys) {
        $figures = foreach ($scheme in 'light', 'dark') {
            foreach ($state in $states) {
                $png = Join-Path $Root "$state\$k-$scheme.png"
                if (-not (Test-Path $png)) { continue }
                $label = "$state, " + $(if ($scheme -eq 'dark') { 'dunkel' } else { 'hell' })
                $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($png))
                "<figure><figcaption>$label</figcaption><img alt='$k $label, erfundene Werte' src='data:image/png;base64,$b64'></figure>"
            }
        }
        "<h2>$(& $enc $(if ($titles[$k]) { $titles[$k] } else { $k }))</h2><div class='phones'>$($figures -join '')</div>"
    }
    $live = ''
    if ($Surface -eq 'mini-app' -and (Test-Path (Join-Path $Root 'nachher'))) {
        $b = @{}
        foreach ($scheme in 'light', 'dark') { $b[$scheme] = [Convert]::ToBase64String($Utf8NoBom.GetBytes((Get-AppPreviewPage -Scheme $scheme))) }
        $live = "<h2>Echte Seite zum Antippen (Stand nachher)</h2><div class='phones'><figure><figcaption>hell</figcaption><iframe id='app-light' title='hell' sandbox='allow-scripts'></iframe></figure><figure><figcaption>dunkel</figcaption><iframe id='app-dark' title='dunkel' sandbox='allow-scripts'></iframe></figure></div>" +
                "<script>function dec(b){return new TextDecoder().decode(Uint8Array.from(atob(b),function(c){return c.charCodeAt(0);}));}document.getElementById('app-light').srcdoc=dec('$($b['light'])');document.getElementById('app-dark').srcdoc=dec('$($b['dark'])');</script>"
    }
    $css = (Get-UiAllColorsCss $tokens 'light') + @'

* { box-sizing: border-box; }
body { margin: 0; padding: 20px 16px 48px; font: 17px/1.6 var(--font); color: var(--ink); background: var(--bg); }
main { max-width: 1200px; margin: 0 auto; }
h1 { font-size: 28px; line-height: 1.15; letter-spacing: -.02em; margin: 0 0 8px; }
h2 { font-size: 21px; line-height: 1.3; margin: 32px 0 8px; }
.note { font-size: 15px; color: var(--gray); margin: 0 0 12px; }
.phones { display: flex; flex-wrap: wrap; gap: 16px; }
figure { margin: 0; width: 280px; max-width: 100%; }
figcaption { font-size: 13.5px; font-weight: 500; color: var(--gray); margin-bottom: 6px; }
img, iframe { display: block; width: 100%; border: 1px solid var(--hairline); border-radius: var(--radius); }
iframe { height: 620px; }
@media (max-width: 640px) { figure { width: 100%; } }
'@
    $h = if ($Title) { $Title } else { $Name }
    $html = "<!DOCTYPE html><html lang='de'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>$(& $enc "Vorschau: $h")</title><style>$css</style></head><body><main><h1>$(& $enc $h)</h1><p class='note'>Alle Werte sind erfunden. Setze deine Markierungen direkt hier, schicke sie an Claude und sag danach &bdquo;fertig&ldquo;, sonst schreib deine Hinweise in den Chat.</p>$($sections -join '')$live</main></body></html>"
    $out = Join-Path $Root 'index.html'
    [System.IO.File]::WriteAllText($out, $html, $Utf8NoBom)
    $mb = [Math]::Round((Get-Item $out).Length / 1MB, 1)
    if ($mb -ge 16) { throw "Seite zu gross fuer ein Artefakt: $mb MB (Grenze 16). Weniger Reiter mit -Screens aufnehmen." }
    Write-Host "Seite: $out ($mb MB). Veroeffentlichen: Skill /ui-task." -ForegroundColor Cyan
}
