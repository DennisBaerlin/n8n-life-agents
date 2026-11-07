#Requires -Version 5.1
# docker_cleanup.ps1 -- raeumt NUR eigene Docker-Altlasten dieses Projekts auf (Test-Substrate, Test-DBs, Installer-Probe-Container).
# Standard ist eine Liste ohne Loeschen; erst -Apply loescht. Nie `prune`, nie `--all`, nie fremde Objekte.
#
# Was als eigen gilt (scripts/lib/docker_cleanup_select.ps1):
#   Container  gestoppt (exited/created/dead) UND Label lifeagents.substrate* / io.lifeagents.* ODER Name n8ntest*, lifeagents-dbtest*,
#              ta-voltest*, ta-*test*. Laufende Container bleiben immer stehen.
#   Volumes    nur die anonymen Volumes der eigenen Container, und zwar ueber `docker rm -fv` mit dem Container. Benannte Volumes
#              und alles Fremde bleiben. WARNUNG -IncludeOrphanAnonymousVolumes (Standard aus): loescht zusaetzlich ALLE anonymen
#              Volumes (64-Hex-Name) ohne Container, auch Altlasten laengst geloeschter eigener Container. Docker kann sie keinem
#              Projekt zuordnen, es trifft darum auch verwaiste Volumes fremder Docker-Projekte.
#   Images     Zwischenstaende ohne Namen (dangling) mit Label lifeagents.substrate-base oder io.lifeagents.install.
# Voraussetzung: Docker-Daemon. Ohne Docker meldet das Skript es und endet mit Exit 0.
#
# Usage:  .\scripts\dev\docker_cleanup.ps1            # zeigt, was entfernt wuerde (WhatIf)
#         .\scripts\dev\docker_cleanup.ps1 -Apply     # loescht die gezeigte Liste
#         .\scripts\dev\docker_cleanup.ps1 -Apply -IncludeOrphanAnonymousVolumes   # zusaetzlich verwaiste anonyme Volumes (siehe Warnung oben)
# Exit-Code 0. Test: scripts/dev/docker_cleanup_test.ps1.
param([switch]$Apply, [switch]$IncludeOrphanAnonymousVolumes)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\docker_cleanup_select.ps1')

function Invoke-Docker([string[]]$CmdArgs) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker @CmdArgs 2>$null } finally { $ErrorActionPreference = $eap }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out | Where-Object { $_ }) }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue) -or (Invoke-Docker @('info')).Code -ne 0) {
    Write-Host 'Docker nicht erreichbar, nichts zu tun.'; exit 0
}
$mode = if ($Apply) { 'LOESCHEN' } else { 'WhatIf (nur Liste, -Apply loescht)' }
Write-Host "docker_cleanup: $mode" -ForegroundColor Cyan

$containers = @(Select-StoppedOwnContainers @((Invoke-Docker @('ps', '-a', '--format', '{{.Names}}|{{.State}}|{{.Labels}}')).Out | ForEach-Object { ConvertFrom-ContainerLine "$_" }))
$images = @()
foreach ($lbl in $OwnImageLabels) {
    $images += @((Invoke-Docker @('images', '-q', '-f', 'dangling=true', '-f', "label=$lbl")).Out)
}
$images = @($images | Sort-Object -Unique)

Write-Host ("Container (gestoppt, eigen): {0}" -f $containers.Count)
$containers | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.State) }
if ($IncludeOrphanAnonymousVolumes) {
    $orphans = @(Select-DanglingAnonymousVolumes @((Invoke-Docker @('volume', 'ls', '-q', '-f', 'dangling=true')).Out))
    Write-Host ("WARNUNG: {0} verwaiste anonyme Volumes; Docker ordnet sie keinem Projekt zu, es koennen fremde sein." -f $orphans.Count) -ForegroundColor Yellow
} else {
    Write-Host 'Anonyme Volumes: nur die der Container oben (rm -fv); verwaiste andere bleiben (-IncludeOrphanAnonymousVolumes).'
}
Write-Host ("Eigene dangling Images: {0}" -f $images.Count)
$images | ForEach-Object { Write-Host "  $_" }

if (-not $Apply) { Write-Host 'WhatIf: nichts geloescht.'; exit 0 }

foreach ($c in $containers) { [void](Invoke-Docker @('rm', '-fv', $c.Name)) }   # -v: anonyme Volumes mit (docker_volume_cleanup_test)
$volumes = @()
if ($IncludeOrphanAnonymousVolumes) {
    # nach dem Container-Abbau neu lesen: nur was jetzt keinen Container hat
    $volumes = @(Select-DanglingAnonymousVolumes @((Invoke-Docker @('volume', 'ls', '-q', '-f', 'dangling=true')).Out))
    foreach ($v in $volumes) { [void](Invoke-Docker @('volume', 'rm', $v)) }
}
foreach ($i in $images) { [void](Invoke-Docker @('rmi', $i)) }
Write-Host ("Entfernt: {0} Container (mit ihren anonymen Volumes), {1} verwaiste Volumes, {2} Images." -f $containers.Count, $volumes.Count, $images.Count)
exit 0
