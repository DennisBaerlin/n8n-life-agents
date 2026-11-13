#Requires -Version 5.1
# serve_app_preview.ps1 -- Live-Vorschau der Mini-App fuer den Browser der Claude-Desktop-App (Vorschau-Eintrag "mini-app"
# in .claude/launch.json). Liefert die echte Seite packages/core/build/app/index.html mit dem echten Renderer und einem
# festen, erfundenen View-Modell (Bildschirm Vermoegen) ueber den fetch-Stub aus scripts/dev/lib/app_preview.ps1 --
# kein Substrat, keine DB, kein Telegram. Zeigt die Seite in Handybreite (hell/dunkel) im Desktop-Browser; Stellen darin
# lassen sich markieren.
# Jede Anfrage baut die Seite neu (Aenderung an index.html, Texten oder dem Datenmodell app_preview_data.json -> Neuladen
# genuegt); nur eine Aenderung an lib/app_preview.ps1 oder am Renderer (build_helpers.ps1) braucht einen Neustart des Servers.
#   .\scripts\dev\serve_app_preview.ps1 [-Port 8765]
#   http://localhost:8765/              hell        http://localhost:8765/?scheme=dark   dunkel
# Strg+C (bzw. Stoppen der Vorschau) beendet den Server. Nur localhost (HttpListener braucht dafuer keine Admin-Rechte).
param([int]$Port = 8765)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $RepoRoot 'scripts\build\lib\build_helpers.ps1')
. (Join-Path $PSScriptRoot 'lib\app_preview.ps1')

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Mini-App-Vorschau: http://localhost:$Port/  (dunkel: ?scheme=dark). Strg+C beendet." -ForegroundColor Cyan
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response
        # HEAD (Port-Check der Desktop-App vor dem Oeffnen des Tabs): Header ohne Body; ein Body-Write wirft bei HEAD
        # "ueberschreitet Content-Length" und beendet den Server
        $isHead = $ctx.Request.HttpMethod -eq 'HEAD'
        try {
            if ($ctx.Request.Url.AbsolutePath -ne '/') {
                $res.StatusCode = 404
            } else {
                $scheme = if ($ctx.Request.QueryString['scheme'] -eq 'dark') { 'dark' } else { 'light' }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-AppPreviewPage -Scheme $scheme))
                $res.ContentType = 'text/html; charset=utf-8'
                $res.Headers['Cache-Control'] = 'no-store'
                $res.ContentLength64 = $bytes.Length
                if (-not $isHead) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
                Write-Host "  $($ctx.Request.HttpMethod) $($ctx.Request.RawUrl) -> $scheme" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [FEHLER] $($_.Exception.Message)" -ForegroundColor Red
            try {
                $res.StatusCode = 500
                $msg = [System.Text.Encoding]::UTF8.GetBytes("Vorschau-Fehler: $($_.Exception.Message)")
                $res.ContentType = 'text/plain; charset=utf-8'
                if (-not $isHead) { $res.OutputStream.Write($msg, 0, $msg.Length) }
            } catch { }
        } finally {
            $res.Close()
        }
    }
} finally {
    $listener.Stop()
}
