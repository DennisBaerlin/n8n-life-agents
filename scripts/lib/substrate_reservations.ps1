#Requires -Version 5.1
# Reservierung von n8n-Test-Substrat-Plaetzen: Liste, Frist und Platz-Entscheidung. Dot-Sourcing-Bibliothek fuer
# scripts/reserve_substrate_slot.ps1 (Bedienung durch die Leitung); Wait-SubstrateSlot (unten) rufen beide Bootstraps.
# Test: scripts/dev/substrate_reservation_test.ps1.
#
# Warum: Wait-SubstrateSlot zaehlt nur laufende Substrate. Hat die Leitung einen Platz schon an eine wartende Session
# zugesagt, der Container laeuft aber noch nicht, nimmt ihn eine andere Session in der Luecke weg. Die Leitung
# traegt die Zusage deshalb als Reservierung ein; bis zu ihrem Verfall zaehlt sie wie ein laufendes Substrat -- fuer alle
# ausser den reservierten Container selbst.
#
# Liste: gitignored im Haupt-Checkout (.claude/substrate_reservations.txt, Pfad ueber git-common-dir wie
# .claude/sub_sessions.txt), UTF-8 ohne BOM, je Zeile `Container|Zeitpunkt (UTC, ISO 8601)|vergeben von`.
# Frist 60 Min: ein Schnellpfad-Start (-Reset) braucht ~4 Min, ein kalter ~10 Min, dazu kommt die Zeit, bis die wartende
# Session die Zusage liest und ihren Schritt beendet; deutlich laenger haelt ein toter Eintrag (Session abgebrochen) den
# Platz unnoetig bei nur zwei Plaetzen. Erneutes Reservieren desselben Containers setzt die Frist neu.

$SlotReservationTtlMin = 60

function Get-SlotReservationFile {
    $common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
    return (Join-Path (Split-Path $common -Parent) '.claude\substrate_reservations.txt')
}

# Alle Dateizugriffe unter einem benannten Mutex: mehrere Sessions schreiben gleichzeitig (Reservieren, Einloesen).
function Use-SlotReservationLock([scriptblock]$Action) {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\lifeagents-substrate-reservations')
    try {
        [void]$mutex.WaitOne(10000)
        return (& $Action)
    } finally {
        try { $mutex.ReleaseMutex() } catch { $null = $_ }   # nicht erworben (Timeout): nichts freizugeben
        $mutex.Dispose()
    }
}

function Read-SlotReservationLines([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    return @([System.IO.File]::ReadAllLines($File, (New-Object System.Text.UTF8Encoding($false))))
}

function ConvertFrom-SlotReservationLine([string]$Line) {
    $p = $Line -split '\|', 3
    $since = [datetime]::MinValue
    if ($p.Count -ne 3 -or -not $p[0] -or
        -not [datetime]::TryParse($p[1], [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$since)) {
        return $null
    }
    return [pscustomobject]@{ Container = $p[0]; Since = $since; By = $p[2] }
}

# Gueltige Reservierungen (Frist nicht abgelaufen); kaputte Zeilen werden uebergangen.
function Read-SlotReservations {
    param([string]$File = (Get-SlotReservationFile), [datetime]$Now = [datetime]::UtcNow)
    $out = Use-SlotReservationLock {
        foreach ($l in (Read-SlotReservationLines $File)) {
            $r = ConvertFrom-SlotReservationLine $l
            if ($r -and $r.Since.AddMinutes($SlotReservationTtlMin) -gt $Now) { $r }
        }
    }
    return @($out)
}

function Write-SlotReservationFile([string]$File, $Reservations) {
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $lines = [string[]]@($Reservations | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Container, $_.Since.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture), $_.By
    })
    [System.IO.File]::WriteAllLines($File, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Eintragen (oder Frist erneuern); verfallene Zeilen fallen dabei aus der Datei.
function Add-SlotReservation {
    param([string]$File = (Get-SlotReservationFile), [Parameter(Mandatory)][string]$Container, [string]$By = 'leitung', [datetime]$Now = [datetime]::UtcNow)
    Use-SlotReservationLock {
        $keep = @(Read-SlotReservations -File $File -Now $Now | Where-Object { $_.Container -ne $Container })
        $keep += [pscustomobject]@{ Container = $Container; Since = $Now.ToUniversalTime(); By = ($By -replace '[|\r\n]', ' ') }
        Write-SlotReservationFile $File $keep
    }
}

# Freigeben bzw. einloesen. Liefert $true, wenn eine gueltige Reservierung entfernt wurde.
function Remove-SlotReservation {
    param([string]$File = (Get-SlotReservationFile), [Parameter(Mandatory)][string]$Container, [datetime]$Now = [datetime]::UtcNow)
    $hit = Use-SlotReservationLock {
        $all = @(Read-SlotReservations -File $File -Now $Now)
        $keep = @($all | Where-Object { $_.Container -ne $Container })
        if ($keep.Count -ne $all.Count) { Write-SlotReservationFile $File $keep; $true } else { $false }
    }
    return [bool]$hit
}

# Platz-Entscheidung (rein, ohne Docker; zaehlt klassische Container und Docker-Verbuende gemeinsam, Name = $env:N8NTEST_CONTAINER bzw.
# Projektname): Running = Namen laufender fremder Substrate (ohne $Own), Reservations = gueltige
# Reservierungen. Hat $Own selbst eine Reservierung, darf er starten, solange weniger als $Max fremde laufen (Zusage der
# Leitung; Reservierungen anderer zaehlen dann nicht). Sonst belegen laufende Fremde + Reservierungen fuer andere (ohne
# die schon laufenden, sie zaehlen nur einmal) die Plaetze.
function Get-SlotAvailability {
    param([string[]]$Running = @(), $Reservations = @(), [Parameter(Mandatory)][string]$Own, [int]$Max = 2)
    $Reservations = @($Reservations | Where-Object { $_.Container -notlike 'dbport-*' })   # DB-Port-Eintraege belegen keinen Substrat-Platz
    $running = @($Running | Where-Object { $_ -and $_ -ne $Own })
    $forOthers = @($Reservations | Where-Object { $_.Container -ne $Own -and $running -notcontains $_.Container })
    $ownReserved = [bool]@($Reservations | Where-Object { $_.Container -eq $Own }).Count
    $used = if ($ownReserved) { $running.Count } else { $running.Count + $forOthers.Count }
    return [pscustomobject]@{
        Free = ($used -lt $Max); Used = $used; Max = $Max; Running = $running
        ReservedForOthers = $forOthers; OwnReserved = $ownReserved
    }
}

# Text fuer Warte-Hinweis und Abbruch: wer laeuft, wer reserviert hat und wie man selbst an einen Platz kommt.
function Format-SlotBlockedMessage {
    param([Parameter(Mandatory)]$Availability, [Parameter(Mandatory)][string]$Own, [int]$Max = 2)
    $parts = @()
    if ($Availability.Running.Count) { $parts += 'laufen: ' + (($Availability.Running) -join ', ') }
    if ($Availability.ReservedForOthers.Count) {
        $parts += 'reserviert: ' + (($Availability.ReservedForOthers | ForEach-Object {
            '{0} (von {1}, bis {2:HH:mm} UTC)' -f $_.Container, $_.By, $_.Since.AddMinutes($SlotReservationTtlMin)
        }) -join ', ')
    }
    return ('{0} von {1} Plaetzen belegt ({2}). Platz bei der Leitung anfordern, die die Plaetze vergibt; erst nach Zusage der Leitung ' +
            'reservieren mit: .\scripts\reserve_substrate_slot.ps1 -Container {3} -By <dein Name>. ' +
            'Ein run_free_gates -Parallel braucht zwei Plaetze ({3} und {3}-b) und sperrt bei Limit 2 alles andere.') -f `
            $Availability.Used, $Max, ($parts -join '; '), $Own
}

# Eine `docker ps --format '{{.Names}}|{{.Status}}|{{.Labels}}'`-Zeile -> Name, Status ("Up 25 minutes"), Worktree-Label.
# {{.Labels}} statt {{.Label "x"}}: PS 5.1 verstuemmelt eingebettete Anfuehrungszeichen in nativen Argumenten.
function ConvertFrom-SubstrateLine([string]$Line) {
    $n, $status, $labels = $Line -split '\|', 3
    $wt = ((("$labels" -split ',') | Where-Object { $_ -like 'lifeagents.worktree=*' } | Select-Object -First 1) -replace '^lifeagents\.worktree=', '')
    return [pscustomobject]@{ Name = $n; Status = $status; Worktree = [string]$wt }
}

# `{{.Labels}}`-Text ("a=b,c=d") -> Hashtable. Ein Label-Wert mit Komma wird zerschnitten (Docker liefert keine Maskierung).
function ConvertFrom-LabelString([string]$Labels) {
    $h = @{}
    # Komma nur vor `schluessel=` trennt: ein Komma im Wert (Pfad des Checkouts) bleibt drin.
    foreach ($kv in [regex]::Split("$Labels", ',(?=[A-Za-z0-9_.\-/]+=)')) {
        $i = $kv.IndexOf('=')
        if ($i -gt 0) { $h[$kv.Substring(0, $i)] = $kv.Substring($i + 1) }
    }
    return $h
}

# Laufende Substrate des Docker-Verbunds (rein, ohne Docker). Compose setzt auf seine Container nur io.lifeagents.install=<Projekt>
# (die ausgelieferte compose.yml bekommt kein Test-Etikett); den Substrat-Status traegt ein vom Bootstrap selbst angelegtes
# Zustands-Volume (lifeagents.substrate=n8n + lifeagents.worktree=<Checkout>). Ein Projekt zaehlt nur, wenn ein solches Volume
# da ist UND ein Container laeuft: so bleibt eine eigene Installation (gleiches Container-Etikett, kein Volume-Etikett) draussen.
# Zeilen: Volume `Name|Labels`, Container `Name|Status|Labels` (docker volume ls / docker ps --format). Name im Ergebnis = Projekt,
# wie $env:N8NTEST_CONTAINER des klassischen Weges.
function ConvertFrom-ComposeSubstrateRows {
    param([string[]]$VolumeLines = @(), [string[]]$ContainerLines = @())
    $projects = @{}
    foreach ($line in @($VolumeLines | Where-Object { $_ } | Sort-Object)) {
        $p = "$line" -split '\|', 2
        if ($p.Count -ne 2) { continue }
        $l = ConvertFrom-LabelString $p[1]
        $proj = $l['io.lifeagents.install']
        # Erste Zeile nach Name gewinnt: widerspruechliche Worktree-Etiketten (Veto im Aufraeumen) sollen nicht von der Docker-Reihenfolge abhaengen.
        if ($l['lifeagents.substrate'] -eq 'n8n' -and $proj -and -not $projects.ContainsKey($proj)) {
            $projects[$proj] = [string]$l['lifeagents.worktree']
        }
    }
    $seen = @{}
    foreach ($line in @($ContainerLines | Where-Object { $_ })) {
        $p = "$line" -split '\|', 3
        if ($p.Count -ne 3) { continue }
        $cl = ConvertFrom-LabelString $p[2]
        $proj = $cl['io.lifeagents.install']
        # Die Test-Bruecke (lifeagents.substrate=n8n-bridge) laeuft auch, wenn der Verbund angehalten ist: sie belegt keinen Platz.
        if ($cl['lifeagents.substrate'] -eq 'n8n-bridge') { continue }
        if ($proj -and $projects.ContainsKey($proj) -and -not $seen.ContainsKey($proj)) {
            $seen[$proj] = [pscustomobject]@{ Name = $proj; Status = $p[1]; Worktree = $projects[$proj] }
        }
    }
    return @($seen.Values | Sort-Object Name)
}

# Zeilen eines nur lesenden docker-Aufrufs; Docker-Fehler (Daemon aus) = leere Liste. PS 5.1 mit ErrorActionPreference=Stop beim
# Aufrufer: jede stderr-Zeile von docker waere trotz 2>$null ein Abbruch -> nur hier auf Continue.
function Get-DockerLines([string[]]$DockerArgs) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker @DockerArgs 2>$null } finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($out | Where-Object { $_ } | ForEach-Object { "$_" })
}

# Laufende n8n-Test-Substrate beider Unterbauten (nur lesend, `docker ps`/`docker volume ls`). Klassisch: Container-Label
# lifeagents.substrate, vom Basis-Image geerbtes Label lifeagents.substrate-base oder -- mit $Image -- das nackte Image
# (Alt-Container ohne Label; kein ancestor= auf das Basis-Image: BuildKit setzt dafuer keine verlaesslichen Eltern-Verweise).
# Verbund: ConvertFrom-ComposeSubstrateRows. Eine Quelle fuer Wait-SubstrateSlot und `reserve_substrate_slot -List`; die Grenze
# (Max in Get-SlotAvailability) gilt fuer beide zusammen.
# Nacktes Abbild des klassischen Unterbaus (bootstrap_test_n8n.ps1 nimmt es von hier; dieselbe Referenz wie CI genericity.yml).
# Vorgabe der Zaehlung, damit jeder Aufrufer Alt-Container ohne Etikett mitzaehlt.
$ClassicSubstrateImage = 'jrei/systemd-debian:12'
function Get-RunningSubstrates([string]$Image = $ClassicSubstrateImage) {
    $filters = @('label=lifeagents.substrate=n8n', 'label=lifeagents.substrate-base=1')
    if ($Image) { $filters += "ancestor=$Image" }
    $seen = @{}
    foreach ($f in $filters) {
        # PS 5.1 mit ErrorActionPreference=Stop beim Aufrufer: jede stderr-Zeile von docker (Daemon aus, Windows-Runner)
        # waere trotz 2>$null ein Abbruch -> nur hier auf Continue, ein Fehler heisst „kein Substrat“.
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = & docker ps --filter $f --format '{{.Names}}|{{.Status}}|{{.Labels}}' 2>$null } finally { $ErrorActionPreference = $eap }
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($line in @($out | Where-Object { $_ })) {
            $s = ConvertFrom-SubstrateLine "$line"
            if (-not $seen.ContainsKey($s.Name)) { $seen[$s.Name] = $s }
        }
    }
    $vols = Get-DockerLines @('volume', 'ls', '--filter', 'label=lifeagents.substrate=n8n', '--format', '{{.Name}}|{{.Labels}}')
    if ($vols.Count) {
        $cons = Get-DockerLines @('ps', '--filter', 'label=io.lifeagents.install', '--format', '{{.Names}}|{{.Status}}|{{.Labels}}')
        foreach ($s in (ConvertFrom-ComposeSubstrateRows -VolumeLines $vols -ContainerLines $cons)) {
            if (-not $seen.ContainsKey($s.Name)) { $seen[$s.Name] = $s }
        }
    }
    return @($seen.Values | Sort-Object Name)
}

# Wait-SubstrateSlot -Own <name> [-Image <nacktes Abbild>] -- Parallel-Grenze fuer beide Bootstraps (klassisch: Container-Name,
# Verbund: Projektname). Ein Substrat belegt 1-1,5 GB RAM; bei 16 GB und mehreren Sessions lagert Windows sonst aus und alle Tests
# werden langsam. Zaehlt laufende Substrate (Get-RunningSubstrates) ausser genau $Own -- ein <Own>-b von run_free_gates -Parallel
# belegt seinen eigenen Platz -- und gueltige Reservierungen fuer andere. Ab $Max (N8NTEST_MAX_PARALLEL, Vorgabe 2) wird gewartet
# (Poll 30 s, hoechstens $WaitMin = N8NTEST_WAIT_MIN, Vorgabe 15 Min), dann Abbruch. Kein Deckel je Container: ein harter
# --memory-Deckel koennte n8n mitten im Test beenden, die Summe begrenzt diese Grenze. -GetRunning/-ReservationFile nur fuer den
# Test (scripts/dev/substrate_reservation_test.ps1).
function Wait-SubstrateSlot {
    param(
        [Parameter(Mandatory)][string]$Own,
        [string]$Image = $ClassicSubstrateImage,
        [int]$Max = $(if ($env:N8NTEST_MAX_PARALLEL) { [int]$env:N8NTEST_MAX_PARALLEL } else { 2 }),
        [int]$WaitMin = $(if ($env:N8NTEST_WAIT_MIN) { [int]$env:N8NTEST_WAIT_MIN } else { 15 }),
        [string]$ReservationFile = (Get-SlotReservationFile),
        [scriptblock]$GetRunning = { param($img) Get-RunningSubstrates -Image $img }
    )
    $deadline = (Get-Date).AddMinutes($WaitMin)
    while ($true) {
        $running = @(& $GetRunning $Image | Where-Object { $_.Name -and $_.Name -ne $Own } | ForEach-Object { $_.Name })
        $slot = Get-SlotAvailability -Running $running -Reservations @(Read-SlotReservations -File $ReservationFile) -Own $Own -Max $Max
        if ($slot.Free) { return }
        $msg = Format-SlotBlockedMessage -Availability $slot -Own $Own -Max $Max
        if ((Get-Date) -ge $deadline) {
            throw ("Parallel-Limit: $msg`nEin fremdes Substrat nicht abreissen -- warten, bis die besitzende Session es mit -Down " +
                   "beendet, oder die Grenze bewusst per `$env:N8NTEST_MAX_PARALLEL anheben.")
        }
        Write-Host "Parallel-Limit: $msg -- warte auf einen freien Platz ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}
# --- Aufraeumen des Verbunds eines Worktrees (SessionEnd-Hook, stop_test_containers.ps1) ---
# Rein (ohne Docker): was gehoert zum Verbund dieses Checkouts? Zeilen `Name|Labels` je Volume, Container und Netz. Ein Projekt
# gehoert uns, wenn eines seiner Volumes lifeagents.substrate=n8n UND lifeagents.worktree=<Checkout> traegt; alles mit
# io.lifeagents.install=<Projekt> geht dann mit (Compose-Container, -Netze, -Volumes). Zusaetzlich gehoert uns jedes Objekt mit
# lifeagents.worktree=<Checkout> (Schnappschuss-Volumes, Mock-Container). Veto: traegt ein Volume des Projekts das Worktree-
# Etikett eines anderen Checkouts, bleibt das Projekt stehen. Nie ein Projekt ohne Worktree-Etikett (eigene Installation).
# Projektnamen gehen in einen Dateipfad (State-Datei) -> nur der Namensraum von reserve_substrate_slot.ps1.
function Get-WorktreeComposeTargets {
    param([Parameter(Mandatory)][string]$Worktree, [string[]]$VolumeLines = @(), [string[]]$ContainerLines = @(), [string[]]$NetworkLines = @())
    function Read-Rows([string[]]$Lines) {
        foreach ($line in @($Lines | Where-Object { $_ })) {
            $p = "$line" -split '\|', 2
            if ($p.Count -eq 2) { [pscustomobject]@{ Name = $p[0]; L = (ConvertFrom-LabelString $p[1]) } }
        }
    }
    $vols = @(Read-Rows $VolumeLines); $cons = @(Read-Rows $ContainerLines); $nets = @(Read-Rows $NetworkLines)
    $ours = @($vols | Where-Object { $_.L['lifeagents.substrate'] -eq 'n8n' -and $_.L['lifeagents.worktree'] -eq $Worktree -and $_.L['io.lifeagents.install'] } |
        ForEach-Object { $_.L['io.lifeagents.install'] } | Sort-Object -Unique | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9_.-]*$' })
    $projects = @($ours | Where-Object {
        $p = $_
        -not @($vols | Where-Object { $_.L['io.lifeagents.install'] -eq $p -and $_.L['lifeagents.worktree'] -and $_.L['lifeagents.worktree'] -ne $Worktree }).Count
    })
    $pick = {
        param($rows)
        # Allein das Worktree-Etikett genuegt nicht (db_test-Helfer o. ae. duerfen nie mitgehen): Substrat-, Install- oder
        # Schnappschuss-Etikett dazu (Schnappschuss-Volumes tragen bewusst kein Install-Etikett, der Kern fasst sie nie an).
        @($rows | Where-Object {
            $projects -contains $_.L['io.lifeagents.install'] -or
            ($_.L['lifeagents.worktree'] -eq $Worktree -and
                ($_.L['lifeagents.substrate'] -like 'n8n*' -or $_.L['io.lifeagents.install'] -or $_.L['lifeagents.snapshot-key']))
        } | ForEach-Object Name | Sort-Object -Unique)
    }
    return [pscustomobject]@{
        Projects   = $projects
        Containers = @(& $pick $cons)
        Networks   = @(& $pick $nets)
        Volumes    = @(& $pick $vols)
    }
}

# Hauptcheckout/.local: dort liegen die State-Dateien (scripts/lib/n8ntest_state_file.ps1), von allen Worktrees geteilt.
function Get-MainLocalDir {
    $common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
    return (Join-Path (Split-Path $common -Parent) '.local')
}

# Verbund(e) dieses Checkouts abbauen: Container (`rm -fv`, wie jeder Abbau hier) -> Netze -> Volumes -> State-Datei je Projekt.
# Fehlertolerant (Docker aus, Objekt schon weg = weiter). Liefert die Auswahl zurueck.
function Remove-WorktreeComposeSubstrates {
    param([Parameter(Mandatory)][string]$Worktree, [string]$StateDir = (Get-MainLocalDir))
    $listing = {
        param($kind, $format)
        # Eigene Etiketten, zwei Abfragen: alles eines Installationsprojekts (Veto-Pruefung braucht auch fremd etikettierte Volumes) und alles dieses Checkouts.
        $all = @()
        foreach ($f in 'label=io.lifeagents.install', "label=lifeagents.worktree=$Worktree") {
            $a = switch ($kind) {
                'container' { @('ps', '-a', '--filter', $f, '--format', '{{.Names}}|{{.Labels}}') }
                'network'   { @('network', 'ls', '--filter', $f, '--format', '{{.Name}}|{{.Labels}}') }
                'volume'    { @('volume', 'ls', '--filter', $f, '--format', '{{.Name}}|{{.Labels}}') }
            }
            $all += Get-DockerLines $a
        }
        @($all | Sort-Object -Unique)
    }
    $t = Get-WorktreeComposeTargets -Worktree $Worktree -VolumeLines (& $listing 'volume') -ContainerLines (& $listing 'container') -NetworkLines (& $listing 'network')
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        foreach ($c in $t.Containers) { & docker rm -fv $c 2>$null | Out-Null }
        foreach ($n in $t.Networks)   { & docker network rm $n 2>$null | Out-Null }
        foreach ($v in $t.Volumes)    { & docker volume rm $v 2>$null | Out-Null }
    } finally { $ErrorActionPreference = $eap }
    foreach ($p in $t.Projects) {
        Remove-Item -LiteralPath (Join-Path $StateDir "n8ntest_state.$p.json") -Force -ErrorAction SilentlyContinue
    }
    return $t
}

# --- DB-Test-Ports (DBTEST_PG_PORT) ---
# Gleiche Liste, Eintragsname `dbport-<port>`, `By` = DB-Container des Halters. Zwei Sessions mit demselben Port scheiterten
# sonst erst beim `docker run`. Bei der Port-Wahl zaehlen belegte (InUse, aus `docker ps`) und fremd reservierte Ports.
function Get-DbPortEntryName([int]$Port) { return "dbport-$Port" }

# Rein (ohne Docker): $true, wenn $Own den Port nehmen darf. Eigene Reservierung (By = Own) blockiert nicht.
function Test-DbPortFree {
    param([Parameter(Mandatory)][int]$Port, $Reservations = @(), [int[]]$InUse = @(), [Parameter(Mandatory)][string]$Own)
    if ($InUse -contains $Port) { return $false }
    $name = Get-DbPortEntryName $Port
    return -not @($Reservations | Where-Object { $_.Container -eq $name -and $_.By -ne $Own }).Count
}

# Erster freier Port ab $Start (Default 55432 = Standard-Port der Test-DB).
function Find-FreeDbPort {
    param($Reservations = @(), [int[]]$InUse = @(), [Parameter(Mandatory)][string]$Own, [int]$Start = 55432, [int]$Count = 40)
    foreach ($p in $Start..($Start + $Count - 1)) {
        if (Test-DbPortFree -Port $p -Reservations $Reservations -InUse $InUse -Own $Own) { return $p }
    }
    return $null
}

# Add-DbPortReservation -By <halter> [-Port <n>] [-InUse <ports>] -> der reservierte Port, $null wenn -Port nicht frei bzw. keiner frei ist.
# Lesen, Waehlen und Eintragen unter einer Sperre: getrennt bekaemen zwei Sessions denselben freien Port genannt, und der zweite
# Eintrag ersetzte den ersten ohne Meldung.
function Add-DbPortReservation {
    param([string]$File = (Get-SlotReservationFile), [Parameter(Mandatory)][string]$By, [int]$Port, [int[]]$InUse = @(), [datetime]$Now = [datetime]::UtcNow)
    $got = Use-SlotReservationLock {
        $res = @(Read-SlotReservations -File $File -Now $Now)
        $p = if (-not $Port) { Find-FreeDbPort -Reservations $res -InUse $InUse -Own $By }
             elseif (Test-DbPortFree -Port $Port -Reservations $res -InUse $InUse -Own $By) { $Port }
        if ($p) { Add-SlotReservation -File $File -Container (Get-DbPortEntryName $p) -By $By -Now $Now }
        $p
    }
    return $got
}

# Host-Ports laufender Container (`docker ps`, nur lesend); Docker aus = leere Liste.
function Get-DockerHostPorts {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker ps --format '{{.Ports}}' 2>$null } finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) { return @() }
    $ports = foreach ($m in [regex]::Matches(("$($out -join ' ')"), ':(\d+)->')) { [int]$m.Groups[1].Value }
    return @($ports | Sort-Object -Unique)
}
