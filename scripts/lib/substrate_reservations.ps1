#Requires -Version 5.1
# Reservierung von n8n-Test-Substrat-Plaetzen: Liste, Frist und Platz-Entscheidung. Dot-Sourcing-Bibliothek fuer
# scripts/reserve_substrate_slot.ps1 (Bedienung durch die Leitung) und Wait-SubstrateSlot in scripts/dev/bootstrap_test_n8n.ps1.
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

# Platz-Entscheidung (rein, ohne Docker): Running = Namen laufender fremder Substrate (ohne $Own), Reservations = gueltige
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

# Laufende n8n-Test-Substrate (nur lesend, `docker ps`): Container-Label lifeagents.substrate, vom Basis-Image geerbtes Label
# lifeagents.substrate-base oder -- mit $Image -- das nackte Image (Alt-Container ohne Label; kein ancestor= auf das Basis-Image:
# BuildKit setzt dafuer keine verlaesslichen Eltern-Verweise). Eine Quelle fuer Wait-SubstrateSlot und `reserve_substrate_slot -List`.
function Get-RunningSubstrates([string]$Image) {
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
    return @($seen.Values | Sort-Object Name)
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

# Host-Ports laufender Container (`docker ps`, nur lesend); Docker aus = leere Liste.
function Get-DockerHostPorts {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker ps --format '{{.Ports}}' 2>$null } finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) { return @() }
    $ports = foreach ($m in [regex]::Matches(("$($out -join ' ')"), ':(\d+)->')) { [int]$m.Groups[1].Value }
    return @($ports | Sort-Object -Unique)
}
