#Requires -Version 5.1
# Liest die .env der Treiber-Skripte als UTF-8 ohne BOM (Get-Content liest in PS 5.1 eine Datei ohne BOM als
# Windows-1252: Umlaute und Euro im Wert werden zu Muell). Dot-sourcen: . "$PSScriptRoot\lib\dotenv.ps1"
# (aus scripts/dev und scripts/build: "..\lib\dotenv.ps1"). Regel: .claude/rules/powershell.md (Daten-I/O explizit UTF-8).

# Read-DotEnvLines <pfad> -> die Zeilen der Datei (string[]); fehlt die Datei, wirft ReadAllLines wie Get-Content.
function Read-DotEnvLines([string]$Path) {
    # .NET normalisiert anders als Get-Content keinen Backslash: Aufrufer bauen den Pfad mit Backslash, unter Linux (CI) waere das ein Dateiname.
    $native = $Path.Replace([char]92, [System.IO.Path]::DirectorySeparatorChar)
    [System.IO.File]::ReadAllLines($native, (New-Object System.Text.UTF8Encoding($false)))
}
