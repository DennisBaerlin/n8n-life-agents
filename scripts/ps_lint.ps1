#Requires -Version 5.1
# PowerShell-Lint-Gate (prek-Hook `ps-lint` + CI). Faehrt PSScriptAnalyzer ueber scripts/**/*.ps1 +
# packages/*/build/**/*.ps1 (paket-uniforme Build-Defs, WS-B5) mit
# der kuratierten config/PSScriptAnalyzerSettings.psd1. Exit-Code: 0 = sauber, 1 = Findings (NICHT die
# Anzahl als Code -- Windows wrappt Exit-Codes mod 256, 256 Findings -> 0 -> falsches PASS).
# Gate-faehig wie die anderen Domaenen-Linter.
#
# PSScriptAnalyzer ist ein PS-MODUL (kein Binary): auf windows-latest-CI vorinstalliert; lokal liegt es
# in $HOME/.local/psmodules (das via OneDrive umgeleitete Documents-Modulverzeichnis ist kaputt ->
# Install-Module schlaegt dort fehl, s. CONTRIBUTING.md). Darum laeuft der Hook als `language: system`
# in BEIDEN Punkten (kein CI-SKIP).
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Lokales Modul-Verzeichnis vor den Standard-PSModulePath haengen (CI hat das Modul im Standardpfad ->
# Test-Path faellt durch -> Import nutzt die vorinstallierte Version).
$LocalModules = Join-Path $HOME '.local/psmodules'
if (Test-Path $LocalModules) {
    $env:PSModulePath = $LocalModules + [System.IO.Path]::PathSeparator + $env:PSModulePath
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

$Settings = Join-Path $RepoRoot 'config/PSScriptAnalyzerSettings.psd1'
# Paket-uniform (WS-B5): die Build-Defs liegen unter packages/*/build/ -> mit-scannen, sonst verlieren sie
# die PSScriptAnalyzer-Abdeckung. Engine + uebrige Skripte bleiben unter scripts/.
$Targets  = @((Join-Path $RepoRoot 'scripts')) +
            @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'build' } | Where-Object { Test-Path $_ })
$Findings = @($Targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $Settings })

if ($Findings.Count -gt 0) {
    $Findings | Sort-Object ScriptPath, Line | ForEach-Object {
        $rel = $_.ScriptPath.Replace("$RepoRoot\", '')
        Write-Host ("{0}:{1} [{2}] {3}" -f $rel, $_.Line, $_.RuleName, $_.Message)
    }
    Write-Host ""
    Write-Host ("PSScriptAnalyzer: {0} Finding(s)." -f $Findings.Count) -ForegroundColor Red
    exit 1
}
Write-Host "PSScriptAnalyzer: sauber." -ForegroundColor Green
exit 0
