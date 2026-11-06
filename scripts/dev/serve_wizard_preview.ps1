#Requires -Version 5.1
# serve_wizard_preview.ps1 -- Vorschau des Einrichtungs-Wizards fuer den Browser der Claude-Desktop-App (Eintrag "wizard" in
# .claude/launch.json). Liefert die ECHTE Seite (provisioning/wizard/ui) mit den festgehaltenen Seiten-Modellen des echten
# Servers (scripts/dev/lib/wizard_preview.ps1, erfundene Werte) -- kein Container noetig, solange die Sammlung existiert.
# Jede Anfrage baut die Seite neu und liest die Sammlung frisch (Aenderung an ui/ oder neue Aufnahme -> Neuladen genuegt);
# neue Seiten-Modelle: -Refresh (Docker, ~1 Min) oder
# .\scripts\dev\build_ui_review.ps1 -Surface wizard -Capture nachher.
#   .\scripts\dev\serve_wizard_preview.ps1 [-Port 8767] [-Refresh]
#   http://localhost:8767/                 Liste aller Seiten
#   http://localhost:8767/?p=review        eine Seite (Farbschema nach dem System; &scheme=light|dark erzwingt eins)
# Strg+C (bzw. Stoppen der Vorschau) beendet den Server. Nur localhost.
param([int]$Port = 8767, [switch]$Refresh)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'lib\wizard_preview.ps1')
$pages = @(Get-WizardPreviewDump -RepoRoot $RepoRoot -Cached:(-not $Refresh))
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Wizard-Vorschau: http://localhost:$Port/  ($($pages.Count) Seiten). Strg+C beendet." -ForegroundColor Cyan
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response
        $isHead = $ctx.Request.HttpMethod -eq 'HEAD'
        try {
            if ($ctx.Request.Url.AbsolutePath -ne '/') { $res.StatusCode = 404; continue }
            $name = [string]$ctx.Request.QueryString['p']
            $scheme = [string]$ctx.Request.QueryString['scheme']
            if ($scheme -notin @('light', 'dark')) { $scheme = 'auto' }
            # Sammlung bei jedem Aufruf frisch lesen: eine neue Aufnahme (build_ui_review.ps1) zeigt sich ohne Neustart.
            $pages = @(Get-WizardPreviewDump -RepoRoot $RepoRoot -Cached)
            $entry = $pages | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if ($entry) {
                $html = Get-WizardPreviewHtml -RepoRoot $RepoRoot -Entry $entry -Scheme $scheme
            } else {
                $links = ($pages | ForEach-Object { $n = [System.Net.WebUtility]::HtmlEncode($_.name); "<li><a href='/?p=$n'>$n</a> &middot; <a href='/?p=$n&amp;scheme=dark'>dunkel</a></li>" }) -join ''
                $html = "<!DOCTYPE html><html lang='de'><head><meta charset='utf-8'><title>Wizard-Vorschau</title></head><body style='font-family:system-ui;margin:24px'><h1>Wizard-Vorschau (erfundene Werte)</h1><ol>$links</ol></body></html>"
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $res.ContentType = 'text/html; charset=utf-8'
            $res.Headers['Cache-Control'] = 'no-store'
            $res.ContentLength64 = $bytes.Length
            if (-not $isHead) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
        } catch {
            $res.StatusCode = 500
            Write-Host "  Fehler: $($_.Exception.Message)" -ForegroundColor Red
        } finally { $res.Close() }
    }
} finally { $listener.Stop() }