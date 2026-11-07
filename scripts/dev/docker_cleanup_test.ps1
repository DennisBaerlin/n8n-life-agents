#Requires -Version 5.1
# Test von scripts/dev/docker_cleanup.ps1: Auswahl-Logik mit erfundenen Listen (kein Docker, nichts wird geloescht) und, falls Docker
# laeuft, ein WhatIf-Lauf, der die Zahl der Container und Volumes unveraendert lassen muss.
# Usage:  .\scripts\dev\docker_cleanup_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\docker_cleanup_select.ps1')
$failed = 0
function Assert-That($name, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name $detail" -ForegroundColor Red; $script:failed++ }
}

Write-Host 'Auswahl:'
$lines = @(
    'n8ntest-a|exited|',
    'lifeagents-dbtest-x|exited|',
    'ta-voltest-db|created|',
    'misc-sub|exited|lifeagents.substrate=n8n,foo=bar',
    'desk|dead|io.lifeagents.desktop=1',
    'n8ntest-live|running|lifeagents.substrate=n8n',
    'fremd-db|exited|com.example=1',
    'postgres-privat|exited|',
    'nginx|running|'
)
$sel = @(Select-StoppedOwnContainers @($lines | ForEach-Object { ConvertFrom-ContainerLine $_ }) | ForEach-Object Name)
Assert-That 'eigene gestoppte Container gewaehlt' (($sel -join ',') -eq 'n8ntest-a,lifeagents-dbtest-x,ta-voltest-db,misc-sub,desk')
Assert-That 'laufender eigener Container bleibt' ($sel -notcontains 'n8ntest-live')
Assert-That 'fremde Container bleiben' ($sel -notcontains 'fremd-db' -and $sel -notcontains 'postgres-privat' -and $sel -notcontains 'nginx')
$hex = ('ab' * 32)
$v = @(Select-DanglingAnonymousVolumes @($hex, 'pgdata', 'my-volume', ('Z' * 64)))
Assert-That 'nur 64-Hex-Volumes' ($v.Count -eq 1 -and $v[0] -eq $hex)

Write-Host 'WhatIf-Lauf:'
$dockerOk = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    docker info *> $null; $dockerOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
}
if ($dockerOk) {
    $before = @(docker ps -a -q).Count; $vbefore = @(docker volume ls -q).Count
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\dev\docker_cleanup.ps1')
    Assert-That 'Exit 0 und WhatIf-Hinweis' ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'WhatIf: nichts geloescht')
    Assert-That 'Standard fasst verwaiste Volumes nicht an' (($out -join "`n") -notmatch 'WARNUNG' -and ($out -join "`n") -match 'IncludeOrphanAnonymousVolumes')
    $out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\dev\docker_cleanup.ps1') -IncludeOrphanAnonymousVolumes
    Assert-That 'Schalter warnt, loescht im WhatIf trotzdem nichts' (($out2 -join "`n") -match 'WARNUNG' -and ($out2 -join "`n") -match 'WhatIf: nichts geloescht')
    Assert-That 'Container und Volumes unveraendert' (@(docker ps -a -q).Count -eq $before -and @(docker volume ls -q).Count -eq $vbefore)
} else {
    Write-Host '  [SKIP] Docker nicht erreichbar'
}
Write-Host "docker_cleanup_test: $failed Fehler."
exit $failed
