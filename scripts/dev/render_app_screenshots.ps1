#Requires -Version 5.1
# render_app_screenshots.ps1 -- erzeugt die Beispielbilder der Mini-App fuer die Doku-Site
# (docs/site/static/img/app-uebersicht-{hell,dunkel}.png) aus der ECHTEN Seite packages/core/build/app/index.html mit
# dem echten Renderer (Get-UiRenderLibJs) und den Texten aus dem Katalog (packages/*/locales/de.json). Anlass
# (Uebersicht R3, 2026-10-28): die Bilder waren von Hand gemacht und zeigten nach einer Text-Aenderung die alte
# Ueberschrift -> jetzt reproduzierbar, nach jeder sichtbaren Aenderung am Bildschirm Vermoegen neu laufen lassen.
#
# Die Seite (fetch-Stub mit dem erfundenen Datenmodell lib/app_preview_data.json, ohne Telegram-Skript) baut
# scripts/dev/lib/app_preview.ps1 (geteilt mit serve_app_preview.ps1); die Startseite zeigt im Bild den Sollzustand
# ("Alles in Ordnung" statt der Beispiel-Alarme, -CalmHome). Die Kinder-Zeile wird aufgeklappt (zeigt das Aufklappen). Aufnahme per Headless-Chrome (sonst Edge), 390 CSS-px breit, Faktor 2, hell und dunkel
# (--force-dark-mode). Kein Netz, keine DB, kein Container.
#   .\scripts\dev\render_app_screenshots.ps1
# Danach: .\scripts\build_site.ps1
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts\build\lib\build_helpers.ps1')
. (Join-Path $PSScriptRoot 'lib\app_preview.ps1')
. (Join-Path $PSScriptRoot 'lib\headless_shot.ps1')

# Handybreite 390 px, Bild 780 x 1520 px (Faktor 2)
$W = 390; $H = 790
$imgDir = Join-Path $RepoRoot 'docs\site\static\img'
foreach ($shot in @(@{ Name = 'app-uebersicht-hell.png'; Scheme = 'light' }, @{ Name = 'app-uebersicht-dunkel.png'; Scheme = 'dark' })) {
    $page = Get-AppPreviewPage -Scheme $shot.Scheme -Width $W -ExpandKids -NoTransitions -CalmHome
    $tmp = Join-Path $env:TEMP 'lifeagents_app_screenshot.html'
    [System.IO.File]::WriteAllText($tmp, $page, $Utf8NoBom)
    $out = Join-Path $imgDir $shot.Name
    Invoke-HeadlessShot -File $tmp -Out $out -WidthPx $W -HeightPx $H -Scale 2 -Dark:($shot.Scheme -eq 'dark')
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] $out" -ForegroundColor Green
}
Write-Host 'Fertig. Danach: .\scripts\build_site.ps1' -ForegroundColor Cyan
