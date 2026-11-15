#Requires -Version 5.1
# Test der Regel L8 in scripts/layout_lint.ps1 (kein Mojibake): Wegwerf-Dateien mit typischen Folgen von UTF-8, das als
# Windows-1252 gelesen und wieder gespeichert wurde, muessen rot werden; echte Umlaute, Euro, Koreanisch und Ã/Â vor normalen
# Zeichen bleiben gruen. Die Proben entstehen ueber die echte Fehlkette (UTF-8-Bytes als 1252 dekodiert), diese Datei bleibt so sauber.
# Aufruf: .\scripts\dev\layout_lint_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\layout_lint.ps1')).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$cp = [System.Text.Encoding]::GetEncoding(1252)
function ConvertTo-Mojibake([string]$s) { $cp.GetString($u8.GetBytes($s)) }
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$cases = @(
    @{ id = 'umlaut-md';    ext = 'md';   bad = $true;  text = "Hilfs-fns " + (ConvertTo-Mojibake 'dürfen') + " mit in die Datei" }
    @{ id = 'gross-sql';    ext = 'sql';  bad = $true;  text = "-- " + (ConvertTo-Mojibake 'Größe und Übertrag') }
    @{ id = 'quote-json';   ext = 'json'; bad = $true;  text = '{"t": "' + (ConvertTo-Mojibake ([string][char]0x201E + 'Hinweis' + [char]0x201C)) + '"}' }
    @{ id = 'grad-ps1';     ext = 'ps1';  bad = $true;  text = "# 21" + (ConvertTo-Mojibake '°') + "C" }
    @{ id = 'echt-md';      ext = 'md';   bad = $false; text = ('Größe, dürfen, Übertrag, 5 €, ' + [char]0x201E + 'Hinweis' + [char]0x201C + ', 21 °C, 안녕하세요') }
    @{ id = 'fremd-js';     ext = 'js';   bad = $false; text = "// São Paulo, Ãrea? nein: Ã gefolgt von O, Â-Taste" }
)
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ll_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    foreach ($c in $cases) {
        $f = Join-Path $dir "$($c.id).$($c.ext)"
        [System.IO.File]::WriteAllText($f, "erste Zeile`n$($c.text)`n", $u8)
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -MojibakeFile $f
        $red = ($LASTEXITCODE -ne 0)
        if ($red -ne $c.bad) { Fail "$($c.id): erwartet rot=$($c.bad), war rot=$red ($out)" }
        elseif ($c.bad -and ($out -join ' ') -notmatch [regex]::Escape("$($c.id).$($c.ext):2")) { Fail "$($c.id): Fund nennt nicht Datei:Zeile 2 ($out)" }
    }
} finally { Remove-Item -Recurse -Force $dir }

if ($fails -eq 0) { Write-Host "PASS layout_lint_test ($($cases.Count) L8-Faelle)" -ForegroundColor Green }
else { Write-Host "layout_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
