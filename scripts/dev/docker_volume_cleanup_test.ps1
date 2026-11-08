#Requires -Version 5.1
# Selbsttest: der Abbau der Test-Container (-Down, -Reset, SessionEnd-Hook) laesst kein anonymes Docker-Volume zurueck.
# Hintergrund: Die Images der Test-Substrate deklarieren VOLUME (Postgres: /var/lib/postgresql/data); Docker legt dafuer beim Anlegen des
# Containers ein namenloses Volume (64-Hex-Name) an. `docker rm -f` entfernt nur den Container, das Volume bleibt verwaist liegen
# (2026-11-06: 201 Stueck, ~17 GB). Erst `docker rm -fv` raeumt es mit weg. Benannte Volumes fasst `-v` nie an.
#
# Zwei Teile:
#   1) statisch (immer): kein `docker rm` ohne -v in scripts/, .claude/hooks/ und .github/workflows/ (faengt auch -Reset und neue Abbau-Stellen).
#   2) dynamisch (braucht Docker + das Image pgvector/pgvector:pg17 lokal, sonst uebersprungen): je Abbau-Pfad ein Wegwerf-Container nur
#      mit `docker create` (nie gestartet, dauert Sekunden), eigener Name `ta-voltest-*`; Volumes vor dem Abbau merken, danach pruefen.
#      Pfade: bootstrap_test_db.ps1 -Down, bootstrap_test_n8n.ps1 -Down, Hook stop_own_substrate.ps1 (in einem Wegwerf-Worktree, damit
#      er kein echtes Substrat trifft). Ein benanntes Volume am Container muss den Abbau ueberleben.
# Fremde Container und fremde Volumes bleiben unangetastet; aufgeraeumt wird nur, was dieser Test selbst angelegt hat.
# Usage:  .\scripts\dev\docker_volume_cleanup_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$self = $MyInvocation.MyCommand.Path
$failed = 0
function Assert-That([string]$Label, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { Write-Host "  [PASS] $Label" -ForegroundColor Green; return }
    $script:failed++
    Write-Host "  [FAIL] $Label $Detail" -ForegroundColor Red
}
function Invoke-Docker([string[]]$CmdArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    [pscustomobject]@{ Code = $code; Output = @($out) }
}

Write-Host "docker_volume_cleanup_test"

# --- 1) statisch: jede Abbau-Stelle traegt -v ---------------------------------------------------------------------------------
Write-Host "  Abbau-Stellen (docker rm) in scripts/, .claude/hooks/ und .github/workflows/"
$sites = @(Get-ChildItem (Join-Path $repo 'scripts'), (Join-Path $repo '.claude\hooks') -Recurse -Filter '*.ps1' |
    Where-Object { $_.FullName -ne $self })
$sites += @(Get-ChildItem (Join-Path $repo '.github\workflows') -Filter '*.yml')
$bad = @()
$count = 0
foreach ($f in $sites) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        $n++
        if ($line -match "(?i)\bdocker\s+(@\(\s*'rm'|rm\s)") {
            $count++
            if ($line -notmatch "-fv|'-v'|\s-v\s") { $bad += "$($f.FullName.Substring($repo.Length + 1)):$n" }
        }
    }
}
Assert-That "es gibt Abbau-Stellen (sonst prueft das Muster nichts)" ($count -ge 5) "(gefunden: $count)"
Assert-That "jedes docker rm entfernt anonyme Volumes mit (-v)" ($bad.Count -eq 0) "ohne -v: $($bad -join ', ')"

# --- 2) dynamisch ---------------------------------------------------------------------------------------------------------------
$image = 'pgvector/pgvector:pg17'
$haveDocker = (Invoke-Docker @('info', '--format', '{{.ServerVersion}}')).Code -eq 0
if (-not $haveDocker -or (Invoke-Docker @('image', 'inspect', $image)).Code -ne 0) {
    Write-Host "  [SKIP] dynamischer Teil: Docker nicht erreichbar oder Image $image lokal nicht vorhanden (wird hier nie geladen)." -ForegroundColor Yellow
    exit $failed
}

$made = New-Object System.Collections.Generic.List[string]      # Container dieses Tests
$volumes = New-Object System.Collections.Generic.List[string]   # Volumes dieses Tests (Aufraeumen am Ende)
$sandbox = $null
$named = 'ta-voltest-keep'

# Legt den Wegwerf-Container nur an (nie gestartet). Liefert die anonymen Volumes (64-Hex) und prueft, dass es mindestens eines gibt.
function New-Throwaway([string]$Name, [string[]]$Labels = @()) {
    [void](Invoke-Docker @('rm', '-fv', $Name))
    $a = @('create', '--name', $Name, '-v', "${named}:/keep")
    foreach ($l in $Labels) { $a += @('--label', $l) }
    $r = Invoke-Docker ($a + $image)
    if ($r.Code -ne 0) { throw "docker create $Name fehlgeschlagen: $($r.Output -join ' ')" }
    $made.Add($Name)
    # Ohne Anfuehrungszeichen im Format: PS 5.1 entfernt eingebettete " aus nativen Argumenten.
    $m = Invoke-Docker @('inspect', '-f', '{{range .Mounts}}{{.Type}}:{{.Name}} {{end}}', $Name)
    $anon = @(("$($m.Output -join ' ')" -split '\s+') | Where-Object { $_ -match '^volume:[0-9a-f]{64}$' } | ForEach-Object { $_.Substring(7) })
    foreach ($v in $anon) { $volumes.Add($v) }
    return , $anon
}
function Test-Gone([string]$Name, [string[]]$Anon) {
    $c = (Invoke-Docker @('inspect', $Name)).Code -ne 0
    $left = @($Anon | Where-Object { (Invoke-Docker @('volume', 'inspect', $_)).Code -eq 0 })
    $keep = (Invoke-Docker @('volume', 'inspect', $named)).Code -eq 0
    Assert-That "$Name : Container weg" $c
    Assert-That "$Name : kein anonymes Volume uebrig" ($left.Count -eq 0) "(uebrig: $($left -join ', '))"
    Assert-That "$Name : benanntes Volume bleibt" $keep
}
function Invoke-Script([string]$Path, [hashtable]$ScriptParams, [hashtable]$EnvVars) {
    $prev = @{}
    foreach ($k in $EnvVars.Keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $EnvVars[$k]) }
    try { & $Path @ScriptParams *> $null } finally { foreach ($k in $EnvVars.Keys) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) } }
}

try {
    Write-Host "  bootstrap_test_db.ps1 -Down"
    $anon = New-Throwaway 'ta-voltest-db'
    Assert-That "ta-voltest-db : Wegwerf-Container hat ein anonymes Volume (Image deklariert VOLUME)" ($anon.Count -ge 1)
    Invoke-Script (Join-Path $repo 'scripts\bootstrap_test_db.ps1') @{ Down = $true } @{ DBTEST_CONTAINER = 'ta-voltest-db' }
    Test-Gone 'ta-voltest-db' $anon

    Write-Host "  bootstrap_test_n8n.ps1 -Down"
    $anon = New-Throwaway 'ta-voltest-n8n'
    Assert-That "ta-voltest-n8n : Wegwerf-Container hat ein anonymes Volume" ($anon.Count -ge 1)
    Invoke-Script (Join-Path $repo 'scripts\dev\bootstrap_test_n8n.ps1') @{ Down = $true } @{ N8NTEST_CONTAINER = 'ta-voltest-n8n'; N8NTEST_PORT = '5699' }
    Test-Gone 'ta-voltest-n8n' $anon

    Write-Host "  SessionEnd-Hook stop_own_substrate.ps1 (Wegwerf-Worktree)"
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("vol_hook_" + [guid]::NewGuid().ToString('N'))
    $main = Join-Path $sandbox 'main'; $wt = Join-Path $sandbox 'wt'
    New-Item -ItemType Directory -Force $main | Out-Null
    Initialize-GitSandbox $main
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    git -C $main -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init *> $null
    git -C $main worktree add -q -b wt $wt *> $null
    $ErrorActionPreference = $prev
    $wtTop = (git -C $wt rev-parse --show-toplevel).Trim()
    $anon = New-Throwaway 'ta-voltest-hook' @('lifeagents.substrate=n8n', "lifeagents.worktree=$wtTop")
    Assert-That "ta-voltest-hook : Wegwerf-Container hat ein anonymes Volume" ($anon.Count -ge 1)
    $payload = (@{ cwd = $wt } | ConvertTo-Json -Compress)
    $exe = (Get-Process -Id $PID).Path
    $payload | & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo '.claude\hooks\stop_own_substrate.ps1') *> $null
    Test-Gone 'ta-voltest-hook' $anon
} finally {
    # Nur Eigenes aufraeumen: die Wegwerf-Container und die Volumes, die dieser Test selbst notiert hat, plus das benannte Test-Volume.
    foreach ($c in $made) { [void](Invoke-Docker @('rm', '-fv', $c)) }
    foreach ($v in $volumes) { [void](Invoke-Docker @('volume', 'rm', $v)) }
    [void](Invoke-Docker @('volume', 'rm', $named))
    if ($sandbox) { Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($failed -eq 0) { Write-Host "docker_volume_cleanup_test: alle Pruefungen bestanden." -ForegroundColor Green }
else { Write-Host "docker_volume_cleanup_test: $failed Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $failed
