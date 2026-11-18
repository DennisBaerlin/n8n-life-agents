#Requires -Version 5.1
# hook_path_lint.ps1 -- Hook-Kommandos in .claude/settings.json (hartes Gate).
# Ein relativer Hook-Pfad loest sich gegen das Arbeitsverzeichnis der Session auf: aus einem Unterordner startet der Hook
# mit Exit 127 und laeuft nicht (der Fehlstart bricht nichts ab, die Sperre fehlt still). Der Lint haelt je Kommando:
#   (A) jede Skriptdatei (.ps1 .sh .cmd .bat .js .mjs .py) und jeder Pfad mit ./ ../ oder .claude/ im Kommando ist
#       verankert: `$CLAUDE_PROJECT_DIR/...` (auch `${...}` und `%...%`) oder ein absoluter Pfad;
#   (B) die genannte Datei existiert (`$CLAUDE_PROJECT_DIR` = der Repo-Wurzel dieses Laufs).
# Geprueft wird jedes `command` der settings.json (hooks, statusLine). settings.local.json nur, wenn getrackt
# (sie liegt sonst in .gitignore) oder mit -IncludeLocal.
# Aufruf: .\scripts\hook_path_lint.ps1 [-Root <Baum>] [-IncludeLocal]   (-Root/-IncludeLocal nur fuer scripts/dev/hook_path_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root, [switch]$IncludeLocal)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$anchorRx = [regex]'^(\$CLAUDE_PROJECT_DIR|\$\{CLAUDE_PROJECT_DIR\}|%CLAUDE_PROJECT_DIR%)[\\/]'
$absRx    = [regex]'^([A-Za-z]:[\\/]|/|\\\\)'
$scriptRx = [regex]'\.(ps1|sh|cmd|bat|js|mjs|py)$'
$relRx    = [regex]'^(\.{1,2}[\\/]|\.claude[\\/])'

# Alle `command`-Werte eines JSON-Baums.
function Get-Commands($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) { foreach ($n in $node) { Get-Commands $n }; return }
    if ($node -isnot [pscustomobject]) { return }
    foreach ($p in $node.PSObject.Properties) {
        if ($p.Name -eq 'command' -and $p.Value -is [string]) { $p.Value } else { Get-Commands $p.Value }
    }
}

# Tokens eines Kommandos; Anfuehrungszeichen trennen nicht.
function Get-Tokens([string]$cmd) {
    foreach ($m in [regex]::Matches($cmd, '"([^"]*)"|''([^'']*)''|(\S+)')) {
        if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
    }
}

$files = @('.claude/settings.json')
$local = Join-Path $Root '.claude/settings.local.json'
if (Test-Path $local) {
    $tracked = $false
    if (-not $IncludeLocal) {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $tracked = [bool](git -C $Root ls-files -- '.claude/settings.local.json' 2>$null)
        $ErrorActionPreference = $prevEap
    }
    if ($IncludeLocal -or $tracked) { $files += '.claude/settings.local.json' }
}

$checked = 0
foreach ($rel in $files) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path $path)) { Fail "${rel} fehlt"; continue }
    try { $json = [System.IO.File]::ReadAllText($path, $u8) | ConvertFrom-Json } catch { Fail "${rel} ist kein gueltiges JSON: $($_.Exception.Message)"; continue }
    foreach ($cmd in @(Get-Commands $json)) {
        $checked++
        foreach ($tok in @(Get-Tokens $cmd)) {
            $anchored = $anchorRx.IsMatch($tok) -or $absRx.IsMatch($tok)
            if (-not ($scriptRx.IsMatch($tok) -or $relRx.IsMatch($tok))) { continue }
            if (-not $anchored) {
                Fail "${rel}: Hook-Pfad '$tok' ist nicht verankert (relativ zum Arbeitsverzeichnis: aus einem Unterordner startet der Hook mit Exit 127 und laeuft nicht) -> `"`$CLAUDE_PROJECT_DIR/$($tok -replace '^\.[\\/]', '')`""
                continue
            }
            $abs = $anchorRx.Replace($tok, { param($m) $Root + '/' })
            if (-not (Test-Path -LiteralPath $abs)) { Fail "${rel}: Hook-Datei '$tok' existiert nicht (Pfad aufgeloest: $abs)" }
        }
    }
}

if ($fails -eq 0) { Write-Host "hook_path_lint: OK ($checked Hook-Kommando(s) in $($files.Count) Datei(en))" -ForegroundColor Green }
else { Write-Host "hook_path_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
