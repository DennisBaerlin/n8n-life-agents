#Requires -Version 5.1
# hook_autoload_lint.ps1 -- Skripte im Hook-Umfeld nutzen keine Befehle, die Windows PowerShell 5.1 per Modul-Autoload holt und die mit einem
# geerbten PSModulePath fehlen (hartes Gate). In der CI startet prek unter pwsh 7 jeden Hook als `powershell -NoProfile -File ...`; 5.1 erbt
# den PSModulePath von pwsh 7 und findet Funktionen, die erst beim ersten Aufruf aus einem Modul geladen werden, nicht mehr
# ("The term 'Get-FileHash' is not recognized"). Betroffen sind die Funktionen der Module unter $PSHOME\Modules (Get-FileHash, Expand-Archive,
# Test-NetConnection, ...), nicht die in den Host eingebauten Cmdlets (Select-String, ConvertFrom-Json, ...).
#   Hook-Umfeld = jedes Skript, das ein Eintrag `entry: powershell ... -File <skript>` in .pre-commit-config.yaml startet, und alles, was es
#   per Dot-Sourcing (`. <pfad>.ps1`) laedt. Skripte, die ein Hook per `&` oder `-File` als Kind startet, folgt die Pruefung nicht: sie gelten
#   erst, wenn sie selbst ein Hook-Eintrag sind oder eingebunden werden.
#   Die Liste der Befehle liest die Pruefung beim Lauf aus den Manifesten unter $PSHOME\Modules (nicht aus dem PSModulePath); ein paar bekannte
#   Namen stehen fest dabei, falls die Liste einmal nicht lesbar ist. Definiert ein Skript im Umfeld die Funktion selbst, zaehlt der Aufruf nicht.
#   Statt Get-FileHash: Get-FileSha256 aus scripts/lib/hash.ps1; sonst .NET. Ausnahme einer Zeile: `# hook-autoload: ok <Grund>` am Zeilenende.
# Aufruf: .\scripts\hook_autoload_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/hook_autoload_lint_test.ps1)
#   Gilt nur in Windows PowerShell 5.1 (dem Host der Hooks); unter pwsh 7 meldet sie das und endet mit 0.
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { Write-Host 'hook_autoload_lint: [skip] nur in Windows PowerShell 5.1, dem Host der Hooks' -ForegroundColor DarkGray; exit 0 }
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# Befehle, die 5.1 aus Modulen unter $PSHOME per Autoload holt (Funktionen, keine eingebauten Cmdlets). Die Manifeste werden per Pfad
# gelesen, damit ein geerbter PSModulePath (pwsh 7) die Liste nicht veraendert.
$auto = @{}
$manifests = @(Get-ChildItem "$PSHOME\Modules" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "$($_.Name).psd1" } | Where-Object { Test-Path -LiteralPath $_ })
if ($manifests.Count -gt 0) {
    foreach ($m in (Get-Module -ListAvailable $manifests -ErrorAction SilentlyContinue)) {
        foreach ($c in $m.ExportedFunctions.Keys) { $auto[$c] = $m.Name }
    }
}
foreach ($pair in @(@('Get-FileHash', 'Microsoft.PowerShell.Utility'), @('Expand-Archive', 'Microsoft.PowerShell.Archive'), @('Compress-Archive', 'Microsoft.PowerShell.Archive'),
                    @('Test-NetConnection', 'NetTCPIP'), @('Resolve-DnsName', 'DnsClient'), @('Get-NetTCPConnection', 'NetTCPIP'))) {
    if (-not $auto.ContainsKey($pair[0])) { $auto[$pair[0]] = $pair[1] }
}

$cfgFile = Join-Path $Root '.pre-commit-config.yaml'
if (-not (Test-Path $cfgFile)) { Fail "fehlt: $cfgFile"; Write-Host "hook_autoload_lint: $fails Fehler" -ForegroundColor Red; exit $fails }
$cfg = [System.IO.File]::ReadAllText($cfgFile, $u8)
$entries = @([regex]::Matches($cfg, '(?m)^\s*entry:\s*powershell[^\r\n]*?-File\s+(\S+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

function Rel([string]$p) { $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
function Get-Closure([string]$path, $seen) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $full = (Resolve-Path -LiteralPath $path).Path
    if ($seen.Contains($full)) { return }
    [void]$seen.Add($full)
    $dir = Split-Path $full -Parent
    foreach ($line in [System.IO.File]::ReadAllLines($full, $u8)) {
        $m = [regex]::Match($line, '^\s*\.\s+.*?([A-Za-z0-9_$./\\-]+\.ps1)[''")]')
        if (-not $m.Success) { continue }
        # "$PSScriptRoot\lib\x.ps1" und $RepoRoot\scripts\x.ps1: die Variable vorn weglassen, der Rest ist ein Pfad ab Skriptordner oder Wurzel.
        $name = $m.Groups[1].Value -replace '^\$[A-Za-z]+[\\/]', ''
        foreach ($cand in @((Join-Path $dir $name), (Join-Path $Root $name), (Join-Path (Join-Path $Root 'scripts') $name), (Join-Path $dir (Split-Path $name -Leaf)))) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { Get-Closure $cand $seen; break }
        }
    }
}
$files = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $entries) { Get-Closure (Join-Path $Root $e) $files }

if ($auto.Count -lt 200) { Write-Warning "nur $($auto.Count) Autoload-Funktionen im 5.1-Host gelesen: es gilt die kurze feste Liste" }
# Definiert ein Skript im Umfeld die Funktion selbst, zaehlt der Aufruf nicht.
$defined = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($f in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
    foreach ($fd in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { [void]$defined.Add($fd.Name) }
}
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f, $u8)
    $lines = $text -split "`r?`n"
    foreach ($k in [System.Management.Automation.PSParser]::Tokenize($text, [ref]$null)) {
        if ($k.Type -ne 'Command' -or -not $auto.ContainsKey($k.Content) -or $defined.Contains($k.Content)) { continue }
        if ($lines[$k.StartLine - 1] -match '#\s*hook-autoload:\s*ok\s+\S') { continue }
        $hint = if ($k.Content -eq 'Get-FileHash') { ' -> Get-FileSha256 aus scripts/lib/hash.ps1' } else { ' -> .NET statt des Moduls' }
        Fail "$(Rel $f):$($k.StartLine): $($k.Content) ($($auto[$k.Content])) steht im Hook-Umfeld; Windows PowerShell 5.1 findet es unter pwsh 7 (CI) nicht$hint"
    }
}

if ($fails -eq 0) { Write-Host "hook_autoload_lint: OK ($($entries.Count) Hook-Skript(e), $($files.Count) Datei(en) im Umfeld, $($auto.Count) Autoload-Befehle)" -ForegroundColor Green }
else { Write-Host "hook_autoload_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
