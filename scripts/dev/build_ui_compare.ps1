#Requires -Version 5.1
# build_ui_compare.ps1 -- Vorlage einer Mini-App-Aenderung fuer den Owner (Skill /ui-task): bisherige Darstellung und neue
# Darstellung nebeneinander, jede Abweichung automatisch markiert (scripts/dev/lib/ui_compare.js vergleicht das gerenderte DOM).
# Beide Seiten sind die echte Seite mit dem echten Renderer und erfundenen Werten; die App-Flaeche wird nicht angefasst.
# -Patch ist eine JS-Datei unter .local/, die vor dem Rendern window.__APP_PREVIEW__ aendert und ueber window.__CMP_SIDE__
# ('vorher'|'nachher') die Seiten unterscheidet. So laesst sich ein Vorschlag zeigen, bevor er gebaut ist.
#   .\scripts\dev\build_ui_compare.ps1 -Name kurzer-hinweis -Patch .local\ui_review\kurzer-hinweis\patch.js [-Title 'Was sich aendert']
# Ausgabe: .local/ui_review/<Name>/vergleich.html. Exit 0, bei fehlender Datei Abbruch. Kein Netz, keine DB, kein Container.
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name,
    [Parameter(Mandatory)][string]$Patch,
    [string]$Title = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts\build\lib\build_helpers.ps1')
. (Join-Path $PSScriptRoot 'lib\app_preview.ps1')

$patchJs = [System.IO.File]::ReadAllText((Resolve-Path $Patch).Path, $Utf8NoBom)
$enc = { param($t) [System.Net.WebUtility]::HtmlEncode($t) }

function Get-CompareSide([string]$Scheme, [string]$Side) {
    $page = Get-AppPreviewPage -Scheme $Scheme -Width 375 -NoTransitions -FullHeight
    $inject = "<script>window.__CMP_SIDE__ = '$Side';`n$patchJs`n</script>"
    [Convert]::ToBase64String($Utf8NoBom.GetBytes($page.Replace('<main id="app"', "$inject`n<main id=""app""")))
}

$texts = Get-AppPreviewTexts
$screens = @((Get-AppPreviewDataText | ConvertFrom-Json).screens | ForEach-Object { [ordered]@{ id = $_.screen; title = [string]$texts[[string]$_.title.value] } })
$data = [ordered]@{
    light   = [ordered]@{ vorher = (Get-CompareSide 'light' 'vorher'); nachher = (Get-CompareSide 'light' 'nachher') }
    dark    = [ordered]@{ vorher = (Get-CompareSide 'dark' 'vorher'); nachher = (Get-CompareSide 'dark' 'nachher') }
    screens = $screens
} | ConvertTo-Json -Depth 5 -Compress
$js = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\ui_compare.js'), $Utf8NoBom)

$css = @'
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; font: 15px/1.5 system-ui, sans-serif; background: #F2F3F5; color: #1B1F24; }
h1 { font-size: 20px; margin: 0 0 8px; }
.bar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 10px 0; }
#tabs { display: flex; flex-wrap: wrap; gap: 6px; }
button { font: inherit; padding: 6px 12px; border: 1px solid #C8CDD4; border-radius: 999px; background: #fff; cursor: pointer; }
button.on { background: #1B1F24; color: #fff; }
button.none { color: #7A828C; }
.key { display: flex; flex-wrap: wrap; gap: 14px; font-size: 13px; }
.key i { display: inline-block; width: 14px; height: 14px; border-radius: 3px; margin-right: 5px; vertical-align: -2px; }
.cols { display: flex; gap: 20px; align-items: flex-start; overflow-x: auto; }
figure { margin: 0; flex: none; width: 395px; }
figcaption { font-weight: 600; margin-bottom: 6px; }
iframe { display: block; width: 395px; height: 700px; border: 1px solid #C8CDD4; border-radius: 12px; background: #fff; }
'@
$head = if ($Title) { $Title } else { $Name }
$html = "<!DOCTYPE html><html lang='de'><head><meta charset='utf-8'><title>$(& $enc "Vergleich: $head")</title><style>$css</style></head><body>" +
    "<h1>$(& $enc $head)</h1><div class='bar'><div id='tabs'></div><button id='scheme'>Hell / Dunkel</button></div>" +
    "<div class='key'><span><i style='background:#F5A6CF;border:2px solid #E6007E'></i>Rosa Rahmen: geändert oder neu</span><span><i style='background:#FBE0EE;border:2px dashed #E6007E'></i>Rosa gestrichelt: verschoben</span><span><i style='background:repeating-linear-gradient(135deg,#BDBDBD 0 3px,#fff 3px 6px);border:2px dashed #8C8C8C'></i>Grau gestreift, links: fällt weg oder wird ersetzt</span><span>Diese Markierungen gibt es nur hier, nicht in der App.</span></div>" +
    "<div class='bar' style='font-size:13px;color:#59616B'>Alle Werte sind erfunden. Die Zahl am Reiter nennt die Änderungen. Aufgeklappte Zeilen enthalten eine Änderung.</div>" +
    "<div class='cols'><figure><figcaption>Bisher</figcaption><iframe id='L' title='Bisher'></iframe></figure><figure><figcaption>Neu</figcaption><iframe id='R' title='Neu'></iframe></figure></div>" +
    "<script>window.__CMP__ = $data;</script><script>$js</script></body></html>"

$out = Join-Path $RepoRoot ".local\ui_review\$Name\vergleich.html"
[System.IO.File]::WriteAllText($out, $html, $Utf8NoBom)
Write-Host "Vergleich: $out" -ForegroundColor Cyan
