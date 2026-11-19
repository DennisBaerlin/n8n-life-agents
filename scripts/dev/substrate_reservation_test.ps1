#Requires -Version 5.1
# Test der Substrat-Platz-Reservierung: scripts/lib/substrate_reservations.ps1 (Logik, wie Wait-SubstrateSlot sie nutzt) und
# scripts/reserve_substrate_slot.ps1 (Bedienung). Kein Substrat, keine Kosten; arbeitet nur in einem Temp-Ordner.
# Der Abschnitt "Verbund echt" legt Wegwerf-Projekte s4t5* aus busybox:latest an (nie geladen, keine Ports) und prueft Zaehlung,
# Abbau, SessionEnd-Hook und stop_test_containers.ps1 -ComposeOnly gegen fremde Verbuende; ohne Docker oder busybox entfaellt er.
# Usage:  .\scripts\dev\substrate_reservation_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$sandbox = Join-Path $env:TEMP ("substrate_reservation_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
$file = Join-Path $sandbox 'substrate_reservations.txt'
$lib = Join-Path $repo 'scripts\lib\substrate_reservations.ps1'
$cli = Join-Path $repo 'scripts\reserve_substrate_slot.ps1'
$failed = 0
function Assert-That($name, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name $detail" -ForegroundColor Red; $script:failed++ }
}
function Reset-File { if (Test-Path $file) { Remove-Item $file -Force } }

. $lib
$t0 = [datetime]::new(2026, 11, 6, 10, 0, 0, [DateTimeKind]::Utc)

Write-Host 'Reservierungsliste:'
Reset-File
Assert-That 'ohne Datei: leer' (@(Read-SlotReservations -File $file -Now $t0).Count -eq 0)
Add-SlotReservation -File $file -Container 'sub-a' -By 'leitung' -Now $t0
$r = @(Read-SlotReservations -File $file -Now $t0)
Assert-That 'eintragen: eine Zeile' ($r.Count -eq 1 -and $r[0].Container -eq 'sub-a' -and $r[0].By -eq 'leitung')
$bytes = [System.IO.File]::ReadAllBytes($file)
Assert-That 'UTF-8 ohne BOM' (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
Add-SlotReservation -File $file -Container 'sub-a' -By 'leitung' -Now $t0.AddMinutes(10)
$r = @(Read-SlotReservations -File $file -Now $t0.AddMinutes(10))
Assert-That 'doppelt eintragen: eine Zeile, Frist neu' ($r.Count -eq 1 -and $r[0].Since -eq $t0.AddMinutes(10))
Add-SlotReservation -File $file -Container 'sub-b' -By 'leitung' -Now $t0.AddMinutes(10)
Assert-That 'zweiter Container: zwei Zeilen' (@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10)).Count -eq 2)
Assert-That 'Frist: ein Minute vor Ablauf gueltig' (@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10 + $SlotReservationTtlMin - 1)).Count -eq 2)
Assert-That 'Frist: nach Ablauf verfallen' (@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10 + $SlotReservationTtlMin + 1)).Count -eq 0)
Assert-That 'Frist ist 60 Min' ($SlotReservationTtlMin -eq 60)
Assert-That 'freigeben: Treffer' (Remove-SlotReservation -File $file -Container 'sub-a' -Now $t0.AddMinutes(10))
Assert-That 'freigeben: nur der eine weg' ((@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10)) | ForEach-Object Container) -join ',' -eq 'sub-b')
Assert-That 'freigeben: unbekannter Container = kein Treffer' (-not (Remove-SlotReservation -File $file -Container 'gibt-es-nicht' -Now $t0.AddMinutes(10)))
[System.IO.File]::AppendAllText($file, "kaputte zeile`r`n")
Assert-That 'kaputte Zeile wird uebergangen' (@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10)).Count -eq 1)

Write-Host 'Platz-Entscheidung (Max 2):'
function Slot($running, $reservations, $own = 'me') {
    Get-SlotAvailability -Running $running -Reservations $reservations -Own $own -Max 2
}
function Res($name) { [pscustomobject]@{ Container = $name; Since = $t0; By = 'leitung' } }
Assert-That 'leer: frei' (Slot @() @()).Free
Assert-That 'ein fremdes laeuft: frei' (Slot @('x') @()).Free
Assert-That 'zwei fremde laufen: belegt' (-not (Slot @('x', 'y') @()).Free)
Assert-That 'ein fremdes + Reservierung fuer anderen: belegt' (-not (Slot @('x') @((Res 'other'))).Free)
Assert-That 'zwei Reservierungen fuer andere: belegt' (-not (Slot @() @((Res 'o1'), (Res 'o2'))).Free)
Assert-That 'ein fremdes + EIGENE Reservierung: frei' (Slot @('x') @((Res 'me'))).Free
Assert-That 'zwei fremde + EIGENE Reservierung: belegt (Reservierung schafft keinen Platz)' (-not (Slot @('x', 'y') @((Res 'me'))).Free)
Assert-That 'Reservierung fuer ein schon laufendes fremdes zaehlt nicht doppelt' (Slot @('x') @((Res 'x'))).Free
Assert-That 'eigene Reservierung neben zwei Fremd-Reservierungen: frei (ihm zugesagt, nur laufende zaehlen)' (Slot @() @((Res 'o1'), (Res 'o2'), (Res 'me'))).Free
Assert-That 'eigene Reservierung, zwei fremde laufen: belegt' (-not (Slot @('x','y') @((Res 'me'))).Free)
$s = Slot @('x') @((Res 'o1'))
Assert-That 'Ergebnis nennt Fremd-Reservierungen' ($s.ReservedForOthers.Count -eq 1 -and $s.ReservedForOthers[0].Container -eq 'o1')
Assert-That 'Meldung nennt Reservierung und exaktes Kommando' ((Format-SlotBlockedMessage -Availability $s -Own 'me' -Max 2) -match 'o1' -and (Format-SlotBlockedMessage -Availability $s -Own 'me' -Max 2) -match [regex]::Escape('.\scripts\reserve_substrate_slot.ps1 -Container me'))

$m = Format-SlotBlockedMessage -Availability $s -Own 'me' -Max 2
Assert-That 'Meldung: Reservieren erst nach Zusage der Leitung' ($m -match 'erst nach Zusage der Leitung')
Assert-That 'Meldung: -Parallel braucht zwei Plaetze (<name> und <name>-b)' ($m -match '-Parallel' -and $m -match 'me-b' -and $m -match 'zwei Plaetze')

Write-Host 'Laufende Substrate (docker-ps-Zeile):'
$line = 'sub-a|Up 25 minutes|lifeagents.substrate=n8n,lifeagents.worktree=C:\wt\x,foo=bar'
$p = ConvertFrom-SubstrateLine $line
Assert-That 'Zeile: Name, Status, Worktree' ($p.Name -eq 'sub-a' -and $p.Status -eq 'Up 25 minutes' -and $p.Worktree -eq 'C:\wt\x')
$p = ConvertFrom-SubstrateLine 'alt|Up 2 hours|'
Assert-That 'Zeile ohne Worktree-Label: leerer Worktree' ($p.Name -eq 'alt' -and $p.Worktree -eq '')

Write-Host 'Laufende Substrate des Verbunds (Volume- und Container-Zeilen):'
$wtA = 'C:\wt\a'
$volA = "s4t5a_pgdata|io.lifeagents.install=s4t5a,lifeagents.substrate=n8n,lifeagents.worktree=$wtA"
$volSnap = 's4t5a_snap_pgdata|lifeagents.substrate=n8n-snapshot,lifeagents.worktree=C:\wt\a,lifeagents.snapshot-of=s4t5a'
$conA = 's4t5a-anchor|Up 3 minutes|io.lifeagents.install=s4t5a,com.docker.compose.project=s4t5a'
$conA2 = 's4t5a-n8n|Up 3 minutes|io.lifeagents.install=s4t5a'
$conOwn = 'lifeagents-anchor|Up 2 days|io.lifeagents.install=lifeagents'
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @($conA))
Assert-That 'Projekt mit Traeger-Volume und laufendem Container: ein Substrat' ($c.Count -eq 1)
Assert-That 'Name = Projekt, Worktree aus dem Volume, Status vom Container' ($c[0].Name -eq 's4t5a' -and $c[0].Worktree -eq $wtA -and $c[0].Status -eq 'Up 3 minutes')
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @($conA, $conA2))
Assert-That 'mehrere Container eines Projekts zaehlen einmal' ($c.Count -eq 1)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @($conOwn))
Assert-That 'laufende Fremdinstallation ohne Traeger-Volume (eigene Installation) zaehlt nicht' ($c.Count -eq 0)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @())
Assert-That 'Volume ohne laufenden Container zaehlt nicht' ($c.Count -eq 0)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volSnap) -ContainerLines @($conA))
Assert-That 'Schnappschuss-Volume macht kein Projekt zum Substrat' ($c.Count -eq 0)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA, '', 'kaputt') -ContainerLines @('', 'ohne|etiketten', $conA))
Assert-That 'leere und kaputte Zeilen werden uebergangen' ($c.Count -eq 1)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @() -ContainerLines @($conA))
Assert-That 'ohne Volume-Zeilen: leer' ($c.Count -eq 0)
$two = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA, "s4t5b_pgdata|io.lifeagents.install=s4t5b,lifeagents.substrate=n8n,lifeagents.worktree=C:\wt\b") `
    -ContainerLines @($conA, 's4t5b-anchor|Up 1 minute|io.lifeagents.install=s4t5b'))
Assert-That 'zwei Verbuende: zwei Substrate, nach Name sortiert' (($two | ForEach-Object Name) -join ',' -eq 's4t5a,s4t5b')
$sl = Get-SlotAvailability -Running (@('klassisch') + @($two[0].Name)) -Reservations @() -Own 'me' -Max 2
Assert-That 'ein klassisches + ein Verbund = zwei Plaetze belegt (beide Unterbauten zaehlen zusammen)' (-not $sl.Free)
$sl = Get-SlotAvailability -Running @($two[0].Name) -Reservations @() -Own $two[0].Name -Max 2
Assert-That 'der eigene Verbund zaehlt nicht gegen sich selbst' ($sl.Free -and $sl.Used -eq 0)

Write-Host 'Aufraeum-Auswahl des Verbunds (rein, ohne Docker):'
$R = 'C:\wt\a'
$vols = @(
    "s4t5a_pgdata|io.lifeagents.install=s4t5a,lifeagents.substrate=n8n,lifeagents.worktree=$R",
    's4t5a_var_la|io.lifeagents.install=s4t5a',
    's4t5a_shared|io.lifeagents.install=s4t5a,com.docker.compose.volume=shared',
    "s4t5asnap_pgdata|lifeagents.substrate=n8n-snapshot,lifeagents.worktree=$R,lifeagents.snapshot-of=s4t5a",
    's4t5b_pgdata|io.lifeagents.install=s4t5b,lifeagents.substrate=n8n,lifeagents.worktree=C:\wt\b',
    's4t5b_var_la|io.lifeagents.install=s4t5b',
    'lifeagents_pgdata|io.lifeagents.install=lifeagents')
$cons = @(
    's4t5a-anchor|io.lifeagents.install=s4t5a', 's4t5a-n8n|io.lifeagents.install=s4t5a',
    "s4t5a-mock-tg|io.lifeagents.install=s4t5a,lifeagents.worktree=$R",
    's4t5b-anchor|io.lifeagents.install=s4t5b', 'lifeagents-anchor|io.lifeagents.install=lifeagents')
$nets = @('s4t5a_internal|io.lifeagents.install=s4t5a', 's4t5b_internal|io.lifeagents.install=s4t5b', 'lifeagents_internal|io.lifeagents.install=lifeagents')
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines $vols -ContainerLines $cons -NetworkLines $nets
Assert-That 'Projekt aus Traeger-Volume dieses Checkouts' (($t.Projects -join ',') -eq 's4t5a')
Assert-That 'Container: Projekt-Container und Mock mit Worktree-Etikett, nichts Fremdes' ((($t.Containers | Sort-Object) -join ',') -eq 's4t5a-anchor,s4t5a-mock-tg,s4t5a-n8n')
Assert-That 'Netze: nur die des Projekts' (($t.Networks -join ',') -eq 's4t5a_internal')
Assert-That 'Volumes: Projekt-Volumes plus Schnappschuss, nichts Fremdes' ((($t.Volumes | Sort-Object) -join ',') -eq 's4t5a_pgdata,s4t5a_shared,s4t5a_var_la,s4t5asnap_pgdata')
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines ($vols + "helfer_data|lifeagents.worktree=$R") -ContainerLines ($cons + "helfer-db|lifeagents.worktree=$R") -NetworkLines ($nets + "helfer_net|lifeagents.worktree=$R")
Assert-That 'Objekt nur mit Worktree-Etikett (z. B. ein db_test-Helfer) wird nie gewaehlt' ($t.Containers -notcontains 'helfer-db' -and $t.Volumes -notcontains 'helfer_data' -and $t.Networks -notcontains 'helfer_net')
$bridge = "s4t5a-testbridge|io.lifeagents.install=s4t5a,lifeagents.worktree=$R,lifeagents.substrate=n8n-bridge,lifeagents.bridge-of=s4t5a"
$snapKey = "s4t5asnap_n8n_home|lifeagents.worktree=$R,lifeagents.snapshot-key=0123abcd"
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines ($vols + $snapKey) -ContainerLines ($cons + $bridge) -NetworkLines $nets
Assert-That 'Test-Bruecke des Projekts wird mit abgebaut' ($t.Containers -contains 's4t5a-testbridge')
Assert-That 'Schnappschuss-Volume (nur worktree + snapshot-key, kein Install-Etikett) wird mit abgebaut' ($t.Volumes -contains 's4t5asnap_n8n_home')
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines @() -ContainerLines @($bridge) -NetworkLines @()
Assert-That 'Test-Bruecke ohne Verbund-Volume wird ebenfalls abgebaut (Worktree-Etikett + n8n-bridge)' ($t.Containers -contains 's4t5a-testbridge')
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @('s4t5a-testbridge|Up 1 minute|io.lifeagents.install=s4t5a,lifeagents.substrate=n8n-bridge,lifeagents.bridge-of=s4t5a'))
Assert-That 'laufende Test-Bruecke allein (Verbund angehalten) belegt keinen Platz' ($c.Count -eq 0)
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volA) -ContainerLines @('s4t5a-testbridge|Up 9 minutes|io.lifeagents.install=s4t5a,lifeagents.substrate=n8n-bridge', $conA))
Assert-That 'Bruecke neben laufendem Verbund: ein Substrat, Status vom Verbund-Container' ($c.Count -eq 1 -and $c[0].Status -eq 'Up 3 minutes')
$wc = 'C:\wt\a,b'
$volC = "s4t5c_pgdata|io.lifeagents.install=s4t5c,lifeagents.substrate=n8n,lifeagents.worktree=$wc,com.docker.compose.config-hash=x"
$t = Get-WorktreeComposeTargets -Worktree $wc -VolumeLines @($volC) -ContainerLines @() -NetworkLines @()
Assert-That 'Komma im Worktree-Pfad: Projekt wird gefunden' (($t.Projects -join ',') -eq 's4t5c')
$c = @(ConvertFrom-ComposeSubstrateRows -VolumeLines @($volC) -ContainerLines @('s4t5c-anchor|Up 1 minute|io.lifeagents.install=s4t5c'))
Assert-That 'Komma im Worktree-Pfad: Substrat nennt den ganzen Pfad' ($c.Count -eq 1 -and $c[0].Worktree -eq $wc)
$vA = 's4t5d_pgdata|io.lifeagents.install=s4t5d,lifeagents.substrate=n8n,lifeagents.worktree=C:\wt\a'
$vB = 's4t5d_var_la|io.lifeagents.install=s4t5d,lifeagents.substrate=n8n,lifeagents.worktree=C:\wt\b'
$con = 's4t5d-anchor|Up 1 minute|io.lifeagents.install=s4t5d'
$w1 = (@(ConvertFrom-ComposeSubstrateRows -VolumeLines @($vA, $vB) -ContainerLines @($con)))[0].Worktree
$w2 = (@(ConvertFrom-ComposeSubstrateRows -VolumeLines @($vB, $vA) -ContainerLines @($con)))[0].Worktree
Assert-That 'widerspruechliche Worktree-Etiketten: Ergebnis haengt nicht von der Zeilenfolge ab' ($w1 -eq $w2 -and $w1 -eq 'C:\wt\a')
$t = Get-WorktreeComposeTargets -Worktree 'C:\wt\zz' -VolumeLines $vols -ContainerLines $cons -NetworkLines $nets
Assert-That 'anderer Checkout: nichts' ($t.Projects.Count -eq 0 -and $t.Containers.Count -eq 0 -and $t.Networks.Count -eq 0 -and $t.Volumes.Count -eq 0)
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines ($vols + 's4t5a_x|io.lifeagents.install=s4t5a,lifeagents.worktree=C:\wt\other') -ContainerLines $cons -NetworkLines $nets
Assert-That 'Projekt mit Volume eines anderen Checkouts bleibt stehen (Veto)' ($t.Projects.Count -eq 0 -and $t.Containers -notcontains 's4t5a-anchor' -and $t.Networks.Count -eq 0 -and $t.Volumes -notcontains 's4t5a_var_la')
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines @("bad/name_pgdata|io.lifeagents.install=bad/name,lifeagents.substrate=n8n,lifeagents.worktree=$R") -ContainerLines @() -NetworkLines @()
Assert-That 'Projektname mit unerlaubten Zeichen wird nie Ziel (Pfad der State-Datei)' ($t.Projects.Count -eq 0)
$t = Get-WorktreeComposeTargets -Worktree $R -VolumeLines @() -ContainerLines @() -NetworkLines @()
Assert-That 'leere Eingabe: leeres Ergebnis' ($t.Projects.Count -eq 0 -and $t.Volumes.Count -eq 0)

Write-Host 'Verbund echt (Wegwerf-Projekte s4t5*, busybox, kein Pull, keine Ports):'
$haveDocker = $false
try {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker image inspect busybox:latest *> $null
    $haveDocker = ($LASTEXITCODE -eq 0)
} catch { $null = $_ } finally { $ErrorActionPreference = $eap }
if (-not $haveDocker) {
    Write-Host '  [SKIP] kein Docker oder busybox:latest nicht lokal vorhanden'
} else {
    $wt = 'C:\s4t5-wegwerf-worktree'
    $state = Join-Path $sandbox 'local'
    New-Item -ItemType Directory -Force $state | Out-Null
    function Invoke-D([string[]]$a) {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & docker @a 2>&1 | Out-Null } finally { $ErrorActionPreference = $eap }
        return $LASTEXITCODE
    }
    function Test-DExists([string]$kind, [string]$name) { return ((Invoke-D @($kind, 'inspect', $name)) -eq 0) }
    function New-Probe([string]$proj, [string]$worktree, [string]$stateDir = $state) {
        $lab = @('--label', "io.lifeagents.install=$proj")
        if ($worktree) {
            [void](Invoke-D (@('volume', 'create') + $lab + @('--label', 'lifeagents.substrate=n8n', '--label', "lifeagents.worktree=$worktree", "${proj}_pgdata")))
        }
        [void](Invoke-D (@('volume', 'create') + $lab + @("${proj}_var_la")))
        [void](Invoke-D (@('network', 'create') + $lab + @("${proj}_internal")))
        [void](Invoke-D (@('run', '-d', '--name', "$proj-anchor") + $lab + @('--network', "${proj}_internal", 'busybox:latest', 'sleep', '600')))
        New-Item -ItemType Directory -Force $stateDir | Out-Null
        Set-Content -LiteralPath (Join-Path $stateDir "n8ntest_state.$proj.json") -Value '{}'
    }
    function Remove-Probe([string]$proj) {
        [void](Invoke-D @('rm', '-fv', "$proj-anchor")); [void](Invoke-D @('network', 'rm', "${proj}_internal"))
        foreach ($v in 'pgdata', 'var_la') { [void](Invoke-D @('volume', 'rm', "${proj}_$v")) }
    }
    try {
        New-Probe 's4t5a' $wt                      # unser Verbund
        New-Probe 's4t5b' 'C:\s4t5-fremder-worktree'   # Verbund eines anderen Checkouts
        New-Probe 's4t5c' ''                       # laeuft, hat aber kein Traeger-Volume (wie eine eigene Installation)
        [void](Invoke-D @('volume', 'create', '--label', "lifeagents.worktree=$wt", '--label', 'lifeagents.substrate=n8n-snapshot', 's4t5asnap_pgdata'))
        $run = @(Get-RunningSubstrates | Where-Object { $_.Name -like 's4t5*' })
        Assert-That 'Zaehlung echt: s4t5a und s4t5b zaehlen, s4t5c (ohne Traeger-Volume) nicht' ((($run | ForEach-Object Name) -join ',') -eq 's4t5a,s4t5b')
        Assert-That 'Zaehlung echt: Worktree aus dem Volume-Etikett' (($run | Where-Object Name -eq 's4t5a').Worktree -eq $wt)
        Remove-WorktreeComposeSubstrates -Worktree $wt -StateDir $state | Out-Null
        Assert-That 'Abbau echt: Container, Netz, Volumes und Schnappschuss unseres Verbunds weg' (-not (Test-DExists 'container' 's4t5a-anchor') -and -not (Test-DExists 'network' 's4t5a_internal') -and
            -not (Test-DExists 'volume' 's4t5a_pgdata') -and -not (Test-DExists 'volume' 's4t5a_var_la') -and -not (Test-DExists 'volume' 's4t5asnap_pgdata'))
        Assert-That 'Abbau echt: State-Datei unseres Projekts weg' (-not (Test-Path (Join-Path $state 'n8ntest_state.s4t5a.json')))
        Assert-That 'Abbau echt: Verbund eines anderen Checkouts bleibt komplett' ((Test-DExists 'container' 's4t5b-anchor') -and (Test-DExists 'network' 's4t5b_internal') -and (Test-DExists 'volume' 's4t5b_pgdata') -and (Test-DExists 'volume' 's4t5b_var_la'))
        Assert-That 'Abbau echt: Projekt ohne Worktree-Etikett bleibt komplett' ((Test-DExists 'container' 's4t5c-anchor') -and (Test-DExists 'network' 's4t5c_internal') -and (Test-DExists 'volume' 's4t5c_var_la'))
        Assert-That 'Abbau echt: fremde State-Dateien bleiben' ((Test-Path (Join-Path $state 'n8ntest_state.s4t5b.json')) -and (Test-Path (Join-Path $state 'n8ntest_state.s4t5c.json')))
    } finally {
        foreach ($p in 's4t5a', 's4t5b', 's4t5c') { Remove-Probe $p }
        [void](Invoke-D @('volume', 'rm', 's4t5asnap_pgdata'))
    }

    Write-Host 'stop_test_containers.ps1 -ComposeOnly (Verbund-Zweig):'
    $stopper = Join-Path $repo 'scripts\dev\stop_test_containers.ps1'
    $swt = 'C:\s4t5-stop-worktree'
    try {
        New-Probe 's4t5s' $swt
        New-Probe 's4t5t' 'C:\s4t5-fremder-worktree'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $stopper -ComposeOnly -Worktree $swt -StateDir $state *> $null
        $stopCode = $LASTEXITCODE
        Assert-That 'stop_test_containers -ComposeOnly: Verbund dieses Worktrees weg' (-not (Test-DExists 'container' 's4t5s-anchor') -and -not (Test-DExists 'network' 's4t5s_internal') -and -not (Test-DExists 'volume' 's4t5s_pgdata'))
        Assert-That 'stop_test_containers -ComposeOnly: Exit 0 und State-Datei weg' ($stopCode -eq 0 -and -not (Test-Path (Join-Path $state 'n8ntest_state.s4t5s.json')))
        Assert-That 'stop_test_containers -ComposeOnly: fremder Verbund bleibt' ((Test-DExists 'container' 's4t5t-anchor') -and (Test-DExists 'volume' 's4t5t_pgdata'))
    } finally {
        foreach ($p in 's4t5s', 's4t5t') { Remove-Probe $p }
    }

    Write-Host 'SessionEnd-Hook stop_own_substrate.ps1 (Wegwerf-Repo mit Worktree):'
    . (Join-Path $repo 'scripts\lib\git_sandbox.ps1')
    Clear-GitEnvironment   # im Commit-Hook setzt git GIT_DIR & Co.: ohne das traefe das Wegwerf-Repo das echte
    $hookBox = Join-Path $sandbox 'hookrepo'
    $main = Join-Path $hookBox 'main'; $hwt = Join-Path $hookBox 'wt'
    try {
        New-Item -ItemType Directory -Force $main | Out-Null
        Initialize-GitSandbox $main
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        git -C $main -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init *> $null
        git -C $main worktree add -q -b wt $hwt *> $null
        $ErrorActionPreference = $prev
        $wtTop = (git -C $hwt rev-parse --show-toplevel).Trim()
        $mainTop = (git -C $main rev-parse --show-toplevel).Trim()
        $mainState = Join-Path $main '.local'
        $hook = Join-Path $repo '.claude\hooks\stop_own_substrate.ps1'
        $exe = (Get-Process -Id $PID).Path
        New-Probe 's4t5h' $wtTop $mainState        # Verbund dieses Worktrees
        New-Probe 's4t5i' 'C:\s4t5-fremder-worktree' $mainState
        New-Probe 's4t5k' $mainTop $mainState      # Verbund des Haupt-Checkouts (dort raeumt jede Session selbst auf)
        (@{ cwd = $main } | ConvertTo-Json -Compress) | & $exe -NoProfile -ExecutionPolicy Bypass -File $hook *> $null
        Assert-That 'Haken im Haupt-Checkout: Verbund bleibt' (Test-DExists 'container' 's4t5k-anchor')
        $env:LIFEAGENTS_KEEP_SUBSTRATE = '1'
        try { (@{ cwd = $hwt } | ConvertTo-Json -Compress) | & $exe -NoProfile -ExecutionPolicy Bypass -File $hook *> $null } finally { Remove-Item Env:\LIFEAGENTS_KEEP_SUBSTRATE }
        Assert-That 'Haken mit LIFEAGENTS_KEEP_SUBSTRATE=1: Verbund bleibt' (Test-DExists 'container' 's4t5h-anchor')
        (@{ cwd = $hwt } | ConvertTo-Json -Compress) | & $exe -NoProfile -ExecutionPolicy Bypass -File $hook *> $null
        Assert-That 'Haken im Worktree: Container, Netz und Volumes des eigenen Verbunds weg' (-not (Test-DExists 'container' 's4t5h-anchor') -and -not (Test-DExists 'network' 's4t5h_internal') -and
            -not (Test-DExists 'volume' 's4t5h_pgdata') -and -not (Test-DExists 'volume' 's4t5h_var_la'))
        Assert-That 'Haken: State-Datei des eigenen Verbunds im Haupt-Checkout weg' (-not (Test-Path (Join-Path $mainState 'n8ntest_state.s4t5h.json')))
        Assert-That 'Haken: Verbund eines anderen Checkouts bleibt' ((Test-DExists 'container' 's4t5i-anchor') -and (Test-DExists 'volume' 's4t5i_pgdata') -and (Test-Path (Join-Path $mainState 'n8ntest_state.s4t5i.json')))
        Assert-That 'Haken: Verbund des Haupt-Checkouts bleibt' ((Test-DExists 'container' 's4t5k-anchor') -and (Test-DExists 'volume' 's4t5k_pgdata'))
    } finally {
        foreach ($p in 's4t5h', 's4t5i', 's4t5k') { Remove-Probe $p }
    }
}

Write-Host 'DB-Ports:'
Reset-File
function PortRes($port, $by) { [pscustomobject]@{ Container = (Get-DbPortEntryName $port); Since = $t0; By = $by } }
Assert-That 'Port frei ohne Reservierung' (Test-DbPortFree -Port 55432 -Own 'db-a')
Assert-That 'Port belegt (docker ps): nicht frei' (-not (Test-DbPortFree -Port 55432 -InUse @(55432) -Own 'db-a'))
Assert-That 'Port von anderem reserviert: nicht frei' (-not (Test-DbPortFree -Port 55432 -Reservations @((PortRes 55432 'db-b')) -Own 'db-a'))
Assert-That 'eigene Port-Reservierung blockiert nicht' (Test-DbPortFree -Port 55432 -Reservations @((PortRes 55432 'db-a')) -Own 'db-a')
Assert-That 'freier Port: ueberspringt belegte und reservierte' ((Find-FreeDbPort -Reservations @((PortRes 55433 'db-b')) -InUse @(55432) -Own 'db-a') -eq 55434)
Assert-That 'Port-Eintraege belegen keinen Substrat-Platz' (Slot @('x') @((PortRes 55432 'db-b'))).Free
$s2 = Slot @() @((PortRes 55432 'db-b'), (PortRes 55433 'db-c'))
Assert-That 'Port-Eintraege tauchen nicht als Fremd-Reservierung auf' ($s2.ReservedForOthers.Count -eq 0)

Write-Host 'Bedienung (reserve_substrate_slot.ps1):'
Reset-File
function Invoke-Cli([string[]]$a) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $cli @a -ListFile $file
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
$o = Invoke-Cli @('-Container', 'cli-a', '-By', 'testleitung')
Assert-That 'reservieren: Exit 0, Datei hat den Container' ($o.Code -eq 0 -and (Get-Content $file -Raw) -match 'cli-a')
$o = Invoke-Cli @('-List')
Assert-That '-List nennt Container, Vergeber, Frist' ($o.Code -eq 0 -and $o.Out -match 'cli-a' -and $o.Out -match 'testleitung' -and $o.Out -match 'laeuft ab|bis')
Assert-That '-List zeigt auch laufende Substrate (Abschnitt)' ($o.Out -match 'Laufende Substrate')
$o = Invoke-Cli @('-Release', 'cli-a')
Assert-That '-Release: Exit 0, Datei leer' ($o.Code -eq 0 -and @(Read-SlotReservations -File $file -Now ([datetime]::UtcNow)).Count -eq 0)
$o = Invoke-Cli @('-Release', 'cli-a')
Assert-That '-Release ohne Treffer: kein Fehler' ($o.Code -eq 0)
$o = Invoke-Cli @('-Container', 'bad name!')
Assert-That 'ungueltiger Container-Name: Fehler' ($o.Code -ne 0)
$o = Invoke-Cli @('-DbPort', '59001', '-By', 'db-cli-a')
Assert-That '-DbPort: reserviert dbport-59001' ($o.Code -eq 0 -and (Get-Content $file -Raw) -match 'dbport-59001\|')
$o = Invoke-Cli @('-DbPort', '59001', '-By', 'db-cli-b')
Assert-That '-DbPort von anderem Halter: Fehler' ($o.Code -ne 0)
$o = Invoke-Cli @('-DbPort', '59001', '-By', 'db-cli-a')
Assert-That '-DbPort durch denselben Halter erneut: ok' ($o.Code -eq 0)
$o = Invoke-Cli @('-FreeDbPort', '-By', 'db-cli-b')
Assert-That '-FreeDbPort: reserviert einen anderen Port als den belegten' ($o.Code -eq 0 -and $o.Out -match 'DB-Port \d+ reserviert' -and $o.Out -notmatch 'DB-Port 59001')
$o = Invoke-Cli @('-Release', 'dbport-59001')
Assert-That '-Release dbport-<port> gibt frei' ($o.Code -eq 0)
$o = Invoke-Cli @()
Assert-That 'ohne Parameter: Fehler mit Usage' ($o.Code -ne 0)

Write-Host 'Bedienung: Fehlbedienung bricht ab, reserviert nichts:'
function Assert-Rejected($name, [string[]]$a) {
    Reset-File
    $o = Invoke-Cli $a
    $left = @(Read-SlotReservations -File $file -Now ([datetime]::UtcNow))
    Assert-That $name ($o.Code -ne 0 -and $left.Count -eq 0) ("(Exit $($o.Code), Eintraege: $($left.Count))")
}
Assert-Rejected '-Release -Name x (unbekannter Parameter als Wert): Fehler, x nicht reserviert' @('-Release', '-Name', 'x')
Assert-Rejected '-Container a -Release b (zwei Modi): Fehler' @('-Container', 'cli-a', '-Release', 'cli-b')
Assert-Rejected '-Container a -List (zwei Modi): Fehler' @('-Container', 'cli-a', '-List')
Assert-Rejected '-Container a -DbPort 59002 (zwei Modi): Fehler' @('-Container', 'cli-a', '-DbPort', '59002')
Assert-Rejected '-DbPort 59002 -FreeDbPort (zwei Modi): Fehler' @('-DbPort', '59002', '-FreeDbPort')
Assert-Rejected '-Release a -By x (-By gehoert nicht zu -Release): Fehler' @('-Release', 'cli-a', '-By', 'x')
Assert-Rejected '-List -By x (-By gehoert nicht zu -List): Fehler' @('-List', '-By', 'x')
Assert-Rejected 'ueberzaehlige Angabe (-Container a b): Fehler' @('-Container', 'cli-a', 'ueberzaehlig')
Assert-Rejected '-Container mit Wert -By (Wert beginnt mit -): Fehler' @('-Container', '-By', 'x')
Assert-Rejected 'unbekannter Parameter -Name: Fehler' @('-Name', 'x')
Reset-File
$null = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$cli' -List:`$false -Container cli-sw -ListFile '$file'" 2>$null
Assert-That 'Schalter mit :$false zaehlt nicht als Modus (-List:$false -Container x reserviert x)' ($LASTEXITCODE -eq 0 -and (Get-Content $file -Raw) -match 'cli-sw')

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "substrate_reservation_test: $failed Fehler."
exit $failed
