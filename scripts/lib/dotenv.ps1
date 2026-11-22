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

# ConvertFrom-DotEnvLine <zeile> -> @{Name; Value} oder $null (Kommentar, Leerzeile, kein "="). Die eine Lesart der .env-Werte:
# Leerraum und ein umschliessendes Paar '...' bzw. "..." fallen ab (ein gequoteter Bot-Token passte sonst nicht zur Signaturpruefung).
function ConvertFrom-DotEnvLine([string]$Line) {
    if ($Line -notmatch '^\s*([^#\s=][^=]*)=(.*)$') { return $null }
    $v = $Matches[2].Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
    return [pscustomobject]@{ Name = $Matches[1].Trim(); Value = $v }
}

# Read-DotEnvValues <pfad> -> Hashtable Name -> Wert (letzte Zeile gewinnt).
function Read-DotEnvValues([string]$Path) {
    $map = @{}
    foreach ($l in (Read-DotEnvLines $Path)) { $e = ConvertFrom-DotEnvLine $l; if ($e) { $map[$e.Name] = $e.Value } }
    return $map
}
