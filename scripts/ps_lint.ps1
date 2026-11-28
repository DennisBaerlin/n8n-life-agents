#Requires -Version 5.1
# PowerShell-Lint-Gate (prek-Hook `ps-lint` + CI). Faehrt PSScriptAnalyzer ueber scripts/**/*.ps1 und
# packages/*/build/**/*.ps1 mit der kuratierten config/PSScriptAnalyzerSettings.psd1.
# Aufruf: .\scripts\ps_lint.ps1
# Exit-Code: 0 = sauber, 1 = Findings (bewusst nicht die Anzahl: Windows wrappt Exit-Codes mod 256,
# 256 Findings ergaeben 0).
#
# Voraussetzung: PSScriptAnalyzer ist ein PS-Modul (kein Binary): auf windows-latest-CI vorinstalliert; lokal
# liegt es in $HOME/.local/psmodules (das umgeleitete Documents-Modulverzeichnis ist kaputt, Install-Module
# schlaegt dort fehl, s. CONTRIBUTING.md). Darum laeuft der Hook als `language: system` lokal und in CI.
#
# -Staged (Commit-Hook): analysiert nur die gestagten .ps1-Dateien unter scripts/ und packages/*/build/ (PSScriptAnalyzer-Regeln gelten je
# Datei). Ohne irgendeine gestagte Datei (CI-Checkout, prek --all-files auf sauberem Baum), ohne Schalter und im pre-push-Hook
# laeuft der ganze Baum.
[CmdletBinding()]
param([switch]$Staged)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Lokales Modul-Verzeichnis vorn in den PSModulePath (in CI fehlt es, dort greift die vorinstallierte Version).
$LocalModules = Join-Path $HOME '.local/psmodules'
if (Test-Path $LocalModules) {
    $env:PSModulePath = $LocalModules + [System.IO.Path]::PathSeparator + $env:PSModulePath
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

$Settings = Join-Path $RepoRoot 'config/PSScriptAnalyzerSettings.psd1'
# Build-Defs liegen unter packages/*/build/ und werden mit gescannt; Engine + uebrige Skripte unter scripts/.
$Targets  = @((Join-Path $RepoRoot 'scripts')) +
            @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'build' } | Where-Object { Test-Path $_ })
$StagedFiles = @()
$LimitToStaged = $Staged -and (@(git -C $RepoRoot diff --cached --name-only).Count -gt 0)
if ($LimitToStaged) {
    # Nur Skripte im Lint-Umfang (wie $Targets); .claude/hooks u. a. waren nie Teil dieses Lints.
    $StagedFiles = @(git -C $RepoRoot -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR |
        Where-Object { $_ -match '(?i)^(scripts/|packages/[^/]+/build/).*\.ps1$' } |
        ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ })
}
$Findings = if ($LimitToStaged) { @($StagedFiles | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings $Settings }) }
            else { @($Targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $Settings }) }

if ($Findings.Count -gt 0) {
    # git nennt die Wurzel mit Schraegstrichen, PSScriptAnalyzer die Datei mit Backslash: erst als Systempfad vergleichen.
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $Findings | Sort-Object ScriptPath, Line | ForEach-Object {
        $rel = [System.IO.Path]::GetFullPath($_.ScriptPath)
        if ($rel.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($rootFull.Length).TrimStart('\', '/') }
        Write-Host ("{0}:{1} [{2}] {3}" -f $rel, $_.Line, $_.RuleName, $_.Message)
    }
    Write-Host ""
    Write-Host ("PSScriptAnalyzer: {0} Finding(s)." -f $Findings.Count) -ForegroundColor Red
    exit 1
}
Write-Host "PSScriptAnalyzer: sauber." -ForegroundColor Green
exit 0
