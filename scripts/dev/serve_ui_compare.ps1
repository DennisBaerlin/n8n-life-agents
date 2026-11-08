#Requires -Version 5.1
# serve_ui_compare.ps1 -- liefert die zuletzt gebaute Vergleichsseite (.local/ui_review/*/vergleich.html, build_ui_compare.ps1)
# fuer den Browser der Desktop-App (Vorschau-Eintrag "ui-compare" in .claude/launch.json), der lokale Dateien nicht oeffnet.
#   .\scripts\dev\serve_ui_compare.ps1 [-Port 8768]
# Neu bauen, dann Seite neu laden. Nur localhost, kein Netz, keine DB.
param([int]$Port = 8768)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Vergleich: http://localhost:$Port/" -ForegroundColor Cyan
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response
        try {
            $file = Get-ChildItem (Join-Path $RepoRoot '.local\ui_review') -Filter 'vergleich.html' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($ctx.Request.Url.AbsolutePath -ne '/' -or -not $file) {
                $res.StatusCode = 404
            } else {
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.Headers['Cache-Control'] = 'no-store'
                $res.ContentLength64 = $bytes.Length
                if ($ctx.Request.HttpMethod -ne 'HEAD') { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
            }
        } finally {
            $res.Close()
        }
    }
} finally {
    $listener.Stop()
}
