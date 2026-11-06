#Requires -Version 5.1
# serve_desktop_preview.ps1 -- Live-Vorschau der Start-App (provisioning/desktop/ui) im Browser der Claude-Desktop-App
# (Vorschau-Eintrag "desktop-app" in .claude/launch.json). Liefert die ECHTEN Dateien index.html, app.css, app.js und fuegt
# davor provisioning/desktop/preview/mock.js ein, der die App-Befehle mit erfundenen Antworten ersetzt -- kein Tauri,
# kein Docker, nichts am Rechner. Jede Anfrage liest die Dateien neu (Aenderung -> Neuladen genuegt).
#   .\scripts\dev\serve_desktop_preview.ps1 [-Port 8766]
#   http://localhost:8766/?state=ready&theme=dark&os=win&screen=power     Faelle: Kopf von preview/mock.js
# Strg+C (bzw. Stoppen der Vorschau) beendet den Server. Nur localhost.
param([int]$Port = 8766)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Desktop = Join-Path (Join-Path $RepoRoot 'provisioning') 'desktop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$files = @{
    '/app.css'         = @{ Path = (Join-Path (Join-Path $Desktop 'ui') 'app.css'); Type = 'text/css; charset=utf-8' }
    '/app.js'          = @{ Path = (Join-Path (Join-Path $Desktop 'ui') 'app.js'); Type = 'text/javascript; charset=utf-8' }
    '/preview/mock.js' = @{ Path = (Join-Path (Join-Path $Desktop 'preview') 'mock.js'); Type = 'text/javascript; charset=utf-8' }
}

# index.html mit Vorschau-Zusatz: Attrappe vor app.js, Hell/Dunkel ueber data-theme (statt der Geraete-Einstellung)
function Get-PreviewIndex([string]$Theme) {
    $html = [System.IO.File]::ReadAllText((Join-Path (Join-Path $Desktop 'ui') 'index.html'), $Utf8NoBom)
    $html = $html.Replace('<script src="app.js"></script>', '<script src="/preview/mock.js"></script><script src="app.js"></script>')
    if ($Theme -in 'light', 'dark') { $html = $html.Replace('<html lang="de">', "<html lang=`"de`" data-theme=`"$Theme`">") }
    $html
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Start-App-Vorschau: http://localhost:$Port/  (?state=ready&theme=dark&os=win). Strg+C beendet." -ForegroundColor Cyan
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response
        $isHead = $ctx.Request.HttpMethod -eq 'HEAD'   # Port-Check der Desktop-App: Header ohne Body
        try {
            $p = $ctx.Request.Url.AbsolutePath
            if ($p -eq '/') {
                $bytes = $Utf8NoBom.GetBytes((Get-PreviewIndex $ctx.Request.QueryString['theme']))
                $type = 'text/html; charset=utf-8'
            } elseif ($files.ContainsKey($p)) {
                $bytes = [System.IO.File]::ReadAllBytes($files[$p].Path)
                $type = $files[$p].Type
            } elseif ($p -match '^/art/([a-z0-9][a-z0-9.-]*\.svg)$' -and (Test-Path -LiteralPath ($art = Join-Path (Join-Path (Join-Path $Desktop 'ui') 'art') $Matches[1]))) {
                # Bilder der App (ui/art); der Name ohne Schraegstrich haelt die Anfrage in diesem Ordner
                $bytes = [System.IO.File]::ReadAllBytes($art)
                $type = 'image/svg+xml'
            } else {
                $res.StatusCode = 404
                continue
            }
            $res.ContentType = $type
            $res.Headers['Cache-Control'] = 'no-store'
            # Gleiche Inhalts-Regel wie in der App (tauri.conf.json), ohne die IPC-Adressen
            $res.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'"
            $res.ContentLength64 = $bytes.Length
            if (-not $isHead) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
        } catch {
            Write-Host "  [FEHLER] $($_.Exception.Message)" -ForegroundColor Red
            try { $res.StatusCode = 500 } catch { }
        } finally {
            $res.Close()
        }
    }
} finally {
    $listener.Stop()
}
