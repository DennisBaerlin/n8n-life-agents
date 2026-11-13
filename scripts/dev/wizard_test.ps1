#Requires -Version 5.1
# wizard_test.ps1 -- gratis Tests des Einrichtungs-Wizards (provisioning/wizard): Sicherheit des Servers, Antwort-Datei,
# Durchlauf gegen Attrappen von provision.sh/lifeagents, Bruecke zur CLI-Quelle (bridge.sh), QR-Code. Kein Netz, kein LLM,
# kein Substrat, kein n8n-Testplatz: ein Wegwerf-Container (--rm) aus dem schlanken Test-Bild tests/wizard/Dockerfile (Node 24 +
# bash + jq + curl, einmalig lokal gebaut; -Image ueberschreibt), der
# Repo-Baum schreibgeschuetzt eingehaengt. In CI laeuft dasselbe direkt (Job `wizard` in ci.yml).
#   .\scripts\dev\wizard_test.ps1                      alle Faelle
#   .\scripts\dev\wizard_test.ps1 -Filter durchlauf    nur Tests, deren Name passt (node --test-name-pattern)
#   -Container di4-wizardtest                          eigener Containername je Session/Worktree (Standard: wizardtest-<pid>)
# Exit = Exit-Code von node --test (0 = gruen).
param([string]$Filter = '', [string]$Image = '', [string]$Container = '', [switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Container) { $Container = if ($env:WIZARDTEST_CONTAINER) { $env:WIZARDTEST_CONTAINER } else { "wizardtest-$PID" } }
. (Join-Path $PSScriptRoot 'lib\wizard_preview.ps1')
if (-not $Image) { $Image = Get-WizardTestImage $RepoRoot }
$cmd = 'cd /repo && node --test --test-concurrency=1'
if ($Filter) { $cmd += " --test-name-pattern='$Filter'" }
$cmd += ' tests/wizard/*.test.js'
if ($Verbose) { Write-Host "  Image $Image, Container $Container" -ForegroundColor DarkGray }
Invoke-WizardContainer $Container @('--entrypoint', 'bash', '-v', "${RepoRoot}:/repo:ro", $Image, '-c', $cmd)
$code = $LASTEXITCODE
if ($code -eq 0) { Write-Host '  [PASS] wizard_test' -ForegroundColor Green } else { Write-Host "  [FAIL] wizard_test (Exit $code)" -ForegroundColor Red }
exit $code