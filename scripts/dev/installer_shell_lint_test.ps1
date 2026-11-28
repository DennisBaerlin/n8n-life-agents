#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/installer_shell_lint.ps1 in einem Wegwerf-Baum (-Root): Sperr-Probe und Sperr-Nahme ohne
# Wartezeit ausserhalb der erlaubten Datei, ein nicht eingetragener Zeitgeber, ein exec ohne Programm, das stdin, stdout oder
# stderr der Shell umleitet, und ein ausfuehrbares Skript ohne LANG/LC_ALL muessen rot werden; die Gegenstuecke gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\installer_shell_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\installer_shell_lint.ps1'
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

# (D) `exec` ohne Programm leitet Deskriptoren der Shell selbst um.
Test-Case 'exec schliesst die Sperre und verbiegt dabei stderr der Shell: rot' @{
    "$P/lib/other.sh" = "unlock() {`n  exec 9>&- 2>/dev/null || true`n}`n"
} $true 'other.sh:2'
Test-Case 'exec leitet stdout der Shell um: rot' @{
    "$P/lib/other.sh" = "exec >>`"`$LOG`" 2>&1`n"
} $true 'other.sh:1'
Test-Case 'exec in einer einzeiligen Funktion: rot' @{
    "$P/lib/other.sh" = "unlock() { exec 9>&- 2>/dev/null || true; }`n"
} $true 'other.sh:1'
Test-Case 'exec hinter if ! und hinter else: rot' @{
    "$P/lib/a.sh" = "if ! exec 9>>`"`$LOCK`" 2>/dev/null; then return 0; fi`n"
    "$P/lib/b.sh" = "if x; then :`nelse exec 2>'/tmp/a b'`nfi`n"
} $true 'b.sh:2'
Test-Case 'exec nur mit Deskriptoren ab 3 ist gruen' @{
    "$P/lib/other.sh" = "exec 9>>`"`$LOCK`" || return 0`nexec 9>&-`nexec 3>&2`nexec {OUT}>&1 {IN}<&0`n"
} $false ''
Test-Case 'exec mit Programm darf dessen Ausgabe umleiten' @{
    "$P/lib/other.sh" = "exec bash -c 'true' 2>/dev/null`n( exec sleep 1 >/dev/null 2>&1 )`n"
} $false ''
Test-Case 'eingetragene Umleitung des Installer-Protokolls ist gruen' @{
    "$P/lib/common.sh" = "ui_log_begin() {`n  exec 3>&2`n  exec >>`"`$UI_LOG_FILE`" 2>&1`n  exec 0</dev/null`n}`n"
} $false ''
Test-Case 'exec im Kommentar zaehlt nicht' @{
    "$P/lib/other.sh" = "# exec 2>/dev/null waere falsch`n"
} $false ''

# (E) ausfuehrbare Skripte setzen die Sprach-Umgebung selbst.
Test-Case 'Skript mit Shebang ohne LANG/LC_ALL ist rot' @{
    "$P/neu.sh" = "#!/usr/bin/env bash`nset -euo pipefail`necho x`n"
} $true 'neu.sh'
Test-Case 'Skript mit Shebang und nur LANG ist rot' @{
    "$P/neu.sh" = "#!/usr/bin/env bash`nexport LANG=C.UTF-8`n# export LC_ALL=C.UTF-8`n"
} $true 'neu.sh'
Test-Case 'Skript mit Shebang und beiden Exporten ist gruen' @{
    "$P/neu.sh"       = "#!/usr/bin/env bash`nexport LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive`n"
    "$P/compose/a.sh" = "#!/bin/bash`nexport LANG=C.UTF-8`nexport LC_ALL=C.UTF-8`n"
} $false ''
Test-Case 'gesourcte Bibliothek und Start-App brauchen keinen Export' @{
    "$P/lib/helfer.sh"  = "# helfer.sh`nfoo() { :; }`n"
    "$P/desktop/run.sh" = "#!/usr/bin/env bash`necho x`n"
} $false ''

if ($fails -eq 0) { Write-Host 'PASS installer_shell_lint_test' -ForegroundColor Green } else { Write-Host "FAIL installer_shell_lint_test ($fails)" -ForegroundColor Red }
exit $fails
