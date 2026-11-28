#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/timer_lock_lint.ps1 in einem Wegwerf-Baum (-Root): Sperr-Probe und Sperr-Nahme ohne
# Wartezeit ausserhalb der erlaubten Datei und ein nicht eingetragener Zeitgeber muessen rot werden; die Gegenstuecke
# gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\timer_lock_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\timer_lock_lint.ps1'
$fails = 0

. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')
function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText) { Test-LintCase -Lint $lint -Name $Name -Files $Files -ExpectRed $ExpectRed -ExpectText $ExpectText }

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$P = 'provisioning'
$def = "update_lock_free() {`n  flock -n x true`n}`nupdate_lock_acquire() {`n  flock -n 9`n}`n"
Test-Case 'Probe ohne Wartezeit in einem Zeitgeber-Pfad ist rot' @{
    "$P/lib/common.sh" = $def
    "$P/lib/job.sh"    = "job() {`n  if ! update_lock_free; then return 0; fi`n}`n"
} $true 'job.sh:2'
Test-Case 'Probe mit Wartezeit ist gruen' @{
    "$P/lib/common.sh" = $def
    "$P/lib/job.sh"    = "job() {`n  if ! update_lock_free `"`${WAIT_S:-20}`"; then return 0; fi`n}`n"
} $false ''
Test-Case 'Probe ohne Wartezeit in doctor ist gruen' @{
    "$P/lib/common.sh" = $def
    "$P/doctor.sh"     = "if [ -n `"`$s`" ] && update_lock_free; then echo x; fi`n"
} $false ''
Test-Case 'Nahme ohne Wartezeit ausserhalb des Minuten-Runners ist rot' @{
    "$P/lib/common.sh" = $def
    "$P/lib/other.sh"  = "update_lock_acquire || return 0`n"
} $true 'other.sh:1'
Test-Case 'Nahme ohne Wartezeit im Minuten-Runner ist gruen' @{
    "$P/lib/common.sh"        = $def
    "$P/lib/update_runner.sh" = "update_lock_acquire || { return 0; }`n"
} $false ''
Test-Case 'Nahme mit Wartezeit ist gruen' @{
    "$P/lib/common.sh" = $def
    "$P/lib/other.sh"  = "update_lock_acquire 30 || exit 1`n"
} $false ''
Test-Case 'Kommentarzeile zaehlt nicht' @{
    "$P/lib/common.sh" = $def
    "$P/lib/other.sh"  = "# update_lock_free prueft nur`n"
} $false ''
Test-Case 'unbekannter Zeitgeber ist rot' @{
    "$P/templates/lifeagents-neu.timer.tpl" = "[Timer]`nOnCalendar=*:0/5:00`n"
} $true 'lifeagents-neu'
Test-Case 'eingetragener Zeitgeber ist gruen' @{
    "$P/templates/lifeagents-backup.timer.tpl" = "[Timer]`nOnCalendar=*-*-* 03:30:00`n"
} $false ''

if ($fails -eq 0) { Write-Host 'PASS timer_lock_lint_test' -ForegroundColor Green } else { Write-Host "FAIL timer_lock_lint_test ($fails)" -ForegroundColor Red }
exit $fails
