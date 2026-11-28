#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/hook_autoload_lint.ps1 in einem Wegwerf-Baum (-Root): ein Befehl, den Windows PowerShell 5.1 per Autoload holt
# (Get-FileHash, Expand-Archive, ...), muss im Hook-Skript und in einem von ihm eingebundenen Skript rot werden; ein Kommentar, eine Zeichenkette,
# ein Skript ausserhalb des Hook-Umfelds und die Ausnahme gruen. Dazu das Dateifilter-Gesetz: ein zu enger files-Filter eines Pruef-Hakens, eine fehlende
# Bibliothek, ein ungedeckter Pfad, ls-files ohne Vermerk, ein fehlender -full-Zwilling und verwaiste Ausnahmen sind rot. Kein Docker, kein git.
# Usage: .\scripts\dev\hook_autoload_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle. Die Autoload-Faelle gelten nur in Windows
# PowerShell 5.1 (wie das Gesetz) und werden unter PowerShell 7 uebersprungen.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\hook_autoload_lint.ps1'
$fails = 0
. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')

# -ModulePath: der Lint laeuft mit diesem PSModulePath (das Kind erbt ihn), wie ein Hook unter pwsh 7.
function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText, [string]$ModulePath = '') {
    $savedMp = $env:PSModulePath; if ($ModulePath) { $env:PSModulePath = $ModulePath }
    try { Test-LintCase -Lint $lint -Name $Name -Files $Files -ExpectRed $ExpectRed -ExpectText $ExpectText } finally { $env:PSModulePath = $savedMp }
}

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$cfg = '.pre-commit-config.yaml'
$D = 'scripts'
$S = "$D/dev/neu.ps1"
$hook = "- id: x`n  entry: powershell -NoProfile -File $S`n"
$S2 = "$D/neu2.ps1"   # liegt direkt in scripts: dort ist "$PSScriptRoot\lib\x.ps1" die uebliche Einbindung, ohne ..
$hook2 = "- id: y`n  entry: powershell -NoProfile -File $S2`n"
if ($PSVersionTable.PSEdition -eq 'Desktop') {
Test-Case 'Get-FileHash im Hook-Skript ist rot' @{ $cfg = $hook; $S = "`$h = (Get-FileHash `$f).Hash`n" } $true 'Get-FileSha256'
Test-Case 'Expand-Archive im Hook-Skript ist rot (nicht nur ein Name)' @{ $cfg = $hook; $S = "Expand-Archive -Path a -DestinationPath b`n" } $true 'Expand-Archive'
Test-Case 'Get-FileHash in einem eingebundenen Skript ist rot' @{ $cfg = $hook; $S = ". (Join-Path `$PSScriptRoot '..\lib\hilfe.ps1')`n"; "$D/lib/hilfe.ps1" = "function H { Get-FileHash x }`n" } $true 'hilfe.ps1'
Test-Case 'Einbindung in Anfuehrungszeichen mit $PSScriptRoot (ohne ..) wird verfolgt' @{ $cfg = $hook2; $S2 = ". `"`$PSScriptRoot\lib\hilfe.ps1`"`n"; "$D/lib/hilfe.ps1" = "function H { Get-FileHash x }`n" } $true 'hilfe.ps1'
Test-Case 'zweite Stufe der Einbindung wird verfolgt' @{ $cfg = $hook2; $S2 = ". `"`$PSScriptRoot\lib\a.ps1`"`n"; "$D/lib/a.ps1" = ". (Join-Path `$PSScriptRoot 'b.ps1')`n"; "$D/lib/b.ps1" = "Get-FileHash x`n" } $true 'b.ps1'
Test-Case 'Get-FileHash bleibt rot, wenn der PSModulePath fremd ist (wie unter pwsh 7)' @{ $cfg = $hook; $S = "Get-FileHash x`n" } $true 'Get-FileHash' 'C:\gibt-es-nicht\Modules'
Test-Case 'eigene Funktion gleichen Namens ist gruen' @{ $cfg = $hook; $S = "function Get-FileHash { 'x' }`nGet-FileHash a`n" } $false ''
Test-Case 'Kommentar und Zeichenkette sind gruen' @{ $cfg = $hook; $S = "# Get-FileHash ist hier verboten`n`$t = 'Get-FileHash'`n" } $false ''
Test-Case 'eingebauter Befehl ist gruen' @{ $cfg = $hook; $S = "`$x = Select-String -Path a -Pattern b | ConvertTo-Json`n" } $false ''
Test-Case 'Skript ausserhalb des Hook-Umfelds ist gruen' @{ $cfg = $hook; $S = "`$x = 1`n"; "$D/andere.ps1" = "Get-FileHash x`n" } $false ''
Test-Case 'Ausnahme mit Grund ist gruen' @{ $cfg = $hook; $S = "Get-FileHash x   # hook-autoload: ok nur im 7er-Host`n" } $false ''
Test-Case 'Ausnahme ohne Grund ist rot' @{ $cfg = $hook; $S = "Get-FileHash x   # hook-autoload: ok`n" } $true 'Get-FileHash'

}

# --- Dateifilter der Pruef-Haken ---
# Zusammengesetzt wie oben, auch fuer Eintraege und erwartete Meldungsteile.
$DocX = 'docs' + '/x.md'; $SqlX = 'packages/core/db' + '/x.sql'; $LibX = "$D/lib/hilfe.ps1"; $Probe = "$D/probe_lint.ps1"
$L = "$D/probe_lint.ps1"
$twin = "      - id: probe-lint-full`n        entry: powershell -NoProfile -File $L`n        always_run: true`n        stages: [pre-push]`n"
function New-Cfg([string]$Files, [string]$Notes = '', [string]$Twin = $twin) {
    "      - id: probe-lint`n$Notes        entry: powershell -NoProfile -File $L`n        files: $Files`n`n$Twin"
}
$reads = "`$a = Join-Path `$Root 'packages'`n"
$tree = @{ $L = $reads; 'packages/core/manifest.json' = '{}'; $SqlX = 'select 1;' }
function Test-Filter([string]$Name, [string]$Config, [bool]$ExpectRed, [string]$ExpectText, [hashtable]$Extra = @{}) {
    $files = $tree.Clone(); $files[$cfg] = $Config
    foreach ($k in $Extra.Keys) { $files[$k] = $Extra[$k] }
    Test-Case $Name $files $ExpectRed $ExpectText
}
$wide = '^(packages/|scripts/probe_lint\.ps1$|scripts/lib/)'
Test-Filter 'Filter deckt alles Gelesene: gruen' (New-Cfg $wide) $false ''
Test-Filter 'zu enger Filter (eine gelesene Datei fehlt) ist rot' (New-Cfg '^(packages/core/db/|scripts/probe_lint\.ps1$)') $true "liest 'packages'"
Test-Filter 'Filter ohne das Lint-Skript selbst ist rot' (New-Cfg '^packages/') $true "$Probe nicht"
Test-Filter 'eingebundene Bibliothek ausserhalb des Filters ist rot' (New-Cfg '^(packages/|scripts/probe_lint\.ps1$)') $true "$LibX nicht" @{ $L = ($reads + ". (Join-Path `$PSScriptRoot 'lib\hilfe.ps1')`n"); "$D/lib/hilfe.ps1" = "`$x = 1`n" }
Test-Filter 'Datei, die nur die Bibliothek nennt, zaehlt' (New-Cfg $wide) $true "liest 'config/werte.json'" @{ $L = ($reads + ". (Join-Path `$PSScriptRoot 'lib\hilfe.ps1')`n"); "$D/lib/hilfe.ps1" = "`$f = 'config\werte.json'`n"; 'config/werte.json' = '{}' }
Test-Filter 'verschachteltes Join-Path ergibt einen Pfad, nicht den Oberordner' (New-Cfg $wide) $true "liest 'config/build/a.json'" @{ $L = "`$a = Join-Path (Join-Path (Join-Path `$Root 'config') 'build') 'a.json'`n"; 'config/build/a.json' = '{}'; 'config/andere.json' = '{}' }
Test-Filter 'Muster mit Stern wird aufgeloest' (New-Cfg '^(packages/core/manifest\.json$|scripts/)') $true "liest 'packages/*/db/*.sql'" @{ $L = "`$f = 'packages\*\db\*.sql'`n" }
Test-Filter 'Meldungstext mit Leerzeichen ist kein Lesen' (New-Cfg $wide) $false '' @{ $L = ($reads + "Write-Host '$DocX fehlt'`n"); $DocX = 'x' }
Test-Filter 'Eigenschaftsname und Hashtable-Schluessel sind kein Lesen' (New-Cfg $wide) $false '' @{ $L = ($reads + "`$v = `$m.config.model; `$h = @{ docs = 1 }`n"); 'config/a.json' = '{}'; $DocX = 'x' }
$ex = @{ $L = ($reads + "`$d = 'docs'`n"); $DocX = 'x' }
Test-Filter 'read-ok mit Grund ist gruen' (New-Cfg $wide "        # read-ok: docs -- nur in der Meldung`n") $false '' $ex
Test-Filter 'read-ok ohne Grund ist rot' (New-Cfg $wide "        # read-ok: docs`n") $true 'ohne Grund' $ex
Test-Filter 'verwaistes read-ok ist rot' (New-Cfg $wide "        # read-ok: packages -- alt`n") $true 'verwaist'
Test-Filter 'ls-files ohne Vermerk ist rot' (New-Cfg $wide) $true 'ls-files-ok' @{ $L = ($reads + "`$t = git ls-files`n") }
Test-Filter 'ls-files mit Vermerk ist gruen' (New-Cfg $wide "        # ls-files-ok: Filter deckt die Endungen`n") $false '' @{ $L = ($reads + "`$t = git ls-files`n") }
Test-Filter 'ohne -full-Zwilling rot' (New-Cfg $wide '' '') $true 'probe-lint-full'
Test-Filter 'no-full mit Grund ersetzt den Zwilling' (New-Cfg $wide "        # no-full: eigener CI-Job`n" '') $false ''
Test-Filter 'Zwilling mit anderer Stufe ist rot' (New-Cfg $wide '' ($twin -replace 'pre-push', 'manual')) $true 'Zwilling braucht'
Test-Filter 'always_run-Haken braucht keinen Zwilling' "      - id: probe-lint`n        entry: powershell -NoProfile -File $L`n        always_run: true`n" $false ''
Test-Filter 'Test-Haken (kein Pruef-Skript) bleibt unberuehrt' "      - id: probe-test`n        entry: powershell -NoProfile -File $S`n        files: ^nichts$`n" $false '' @{ $S = $reads }
Test-Filter 'Zwilling mit anderen Argumenten ist rot' (New-Cfg $wide '' ($twin -replace 'probe_lint\.ps1', 'probe_lint.ps1 -Nur')) $true 'Zwilling braucht'
Test-Filter 'Zwilling ohne -Staged ist derselbe Aufruf' ((New-Cfg $wide) -replace '(entry: [^\n]*probe_lint\.ps1)\n        files', "`$1 -Staged`n        files") $false ''
Test-Filter 'Datei in der Wurzel zaehlt' (New-Cfg $wide) $true "liest '.env.example'" @{ $L = ($reads + "`$f = '.env.example'`n"); '.env.example' = 'A=1' }
Test-Filter '$PSScriptRoot ist der Skriptordner, nicht die Wurzel' (New-Cfg $wide) $true "liest 'scripts/build/x.json'" @{ $L = ($reads + "`$f = Join-Path `$PSScriptRoot 'build\x.json'`n"); "$D/build/x.json" = '{}' }
Test-Filter 'Filter mit falscher Gross-/Kleinschreibung ist rot' (New-Cfg '^(Packages/|scripts/probe_lint\.ps1$)') $true "liest 'packages'"
Test-Filter 'Filter als YAML-Block ist rot' (New-Cfg "|`n          (?x)^( packages/ )") $true 'in einer Zeile'
$lib = @{ $L = ($reads + ". (Join-Path `$PSScriptRoot 'lib\hilfe.ps1')`n"); "$D/lib/hilfe.ps1" = "`$f = 'docs'; `$t = git ls-files`n"; $DocX = 'x' }
Test-Filter 'skip-lib: Pfade und ls-files einer Bibliothek zaehlen nicht' (New-Cfg $wide "        # skip-lib: scripts/lib/hilfe.ps1 -- nur eine andere Funktion genutzt`n") $false '' $lib
Test-Filter 'skip-lib ohne Grund ist rot' (New-Cfg $wide "        # skip-lib: scripts/lib/hilfe.ps1`n") $true 'ohne Grund' $lib
Test-Filter 'verwaistes skip-lib ist rot' (New-Cfg $wide "        # skip-lib: scripts/lib/weg.ps1 -- alt`n") $true 'verwaist'
Test-Filter 'skip-lib deckt die Bibliotheksdatei selbst nicht' (New-Cfg '^(packages/|scripts/probe_lint\.ps1$)' "        # skip-lib: scripts/lib/hilfe.ps1 -- nur eine andere Funktion genutzt`n") $true "$LibX nicht" $lib

if ($fails -eq 0) { Write-Host 'PASS hook_autoload_lint_test' -ForegroundColor Green } else { Write-Host "FAIL hook_autoload_lint_test ($fails)" -ForegroundColor Red }
exit $fails
