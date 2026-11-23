#Requires -Version 5.1
# live_read.ps1 -- lesender Zugang der Routinen zum Produktiv-System, gleich fuer klassisch (systemd) und Docker-Verbund.
# Der Skill ruft dieses Skript statt eines eigenen ssh-Rezepts; die Laufzeit des Ziels erkennt es selbst (laeuft der Container
# <projekt>-master -> Verbund). Zugang: LIVE_INSTANCE_HOST/_USER/_SSH_KEY aus der .env des Haupt-Checkouts, nie DEV_INSTANCE_*.
# Nur lesend: das SQL laeuft in einer Sitzung mit default_transaction_read_only = on, die Mitschrift per GET.
# Usage:
#   .\scripts\live_read.ps1 -Runtime                      # gibt 'compose' oder 'classic' aus
#   .\scripts\live_read.ps1 -SqlFile <datei.sql>          # SQL lesend; unausgerichtete Zeilen, Spalten per Tab
#   .\scripts\live_read.ps1 -Usage [-After <id>] [-Limit n]   # Gateway-Mitschrift (/__usage), rohes JSON
#   Test statt Produktiv-System: -Local [-Project <name>] (lokaler Test-Verbund), -Container <name> (klassisches Substrat)
# Exit-Code: 0 = ok; 1 = Zugang fehlt oder Quelle nicht lesbar.
param(
    [switch]$Runtime,
    [string]$SqlFile,
    [switch]$Usage,
    [string]$After = '',
    [int]$Limit = 5000,
    [switch]$Local,
    [string]$Container,
    [string]$Project = 'lifeagents'
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\live_read.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)

if ((@([bool]$Runtime, [bool]$SqlFile, [bool]$Usage) | Where-Object { $_ }).Count -ne 1) { Write-Host 'Genau eines von -Runtime, -SqlFile, -Usage angeben.' -ForegroundColor Red; exit 1 }
if ($Container) { $t = New-LiveTarget 'container' $Project $null $Container }
elseif ($Local) { $t = New-LiveTarget 'local' $Project }
else {
    $main = Split-Path ([string](& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)) -Parent
    $acc = Get-LiveAccess $main
    if (-not $acc) { Write-Host 'LIVE_INSTANCE_HOST oder LIVE_INSTANCE_SSH_KEY fehlt in der .env des Haupt-Checkouts (kein Rueckfall auf DEV_INSTANCE_*).' -ForegroundColor Red; exit 1 }
    $t = New-LiveTarget 'ssh' $Project $acc
}
try {
    if ($Runtime) { Get-LiveRuntime $t; exit 0 }
    if ($SqlFile) { $r = Invoke-LiveSql $t ([System.IO.File]::ReadAllText((Resolve-Path $SqlFile).Path, $u8)) }
    else { $r = Invoke-LiveUsage $t $After $Limit }
} catch { Write-Host "Quelle nicht lesbar: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
if ($r.Rc -ne 0) { Write-Host "Quelle nicht lesbar (Exit $($r.Rc), Laufzeit $($r.Runtime))." -ForegroundColor Red; exit 1 }
$r.Lines
exit 0
