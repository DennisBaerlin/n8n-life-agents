#Requires -Version 5.1
# Auswahl-Logik fuer scripts/dev/docker_cleanup.ps1 (rein, ohne Docker; Test: scripts/dev/docker_cleanup_test.ps1).
# "Eigen" heisst: Label lifeagents.substrate* / io.lifeagents.* ODER ein bekannter Test-Container-Name. Alles andere bleibt unberuehrt.

$OwnLabelPattern = '^(lifeagents\.substrate|io\.lifeagents\.)'
$OwnNamePattern  = '^(n8ntest|lifeagents-dbtest|ta-voltest|ta-[a-z0-9]+test)'
$OwnImageLabels  = @('lifeagents.substrate-base', 'io.lifeagents.install')

# Eine `docker ps -a --format '{{.Names}}|{{.State}}|{{.Labels}}'`-Zeile -> Objekt.
function ConvertFrom-ContainerLine([string]$Line) {
    $n, $state, $labels = $Line -split '\|', 3
    return [pscustomobject]@{ Name = $n; State = $state; Labels = @(("$labels") -split ',' | Where-Object { $_ }) }
}

function Test-OwnContainer($C) {
    if ($C.Name -match $OwnNamePattern) { return $true }
    return [bool]@($C.Labels | Where-Object { $_ -match $OwnLabelPattern }).Count
}

# Eigene, NICHT laufende Container (laufende bleiben immer stehen).
function Select-StoppedOwnContainers($Containers) {
    return @($Containers | Where-Object { $_.State -in @('exited', 'created', 'dead') -and (Test-OwnContainer $_) })
}

# Anonyme Volumes: 64-Hex-Name, kein Container nutzt sie (dangling). Benannte Volumes sind nie Kandidat.
function Select-DanglingAnonymousVolumes([string[]]$DanglingVolumeNames) {
    return @($DanglingVolumeNames | Where-Object { $_ -cmatch '^[0-9a-f]{64}$' })
}
