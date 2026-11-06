#Requires -Version 5.1
# Test der Substrat-Platz-Reservierung: scripts/lib/substrate_reservations.ps1 (Logik, wie Wait-SubstrateSlot sie nutzt) und
# scripts/reserve_substrate_slot.ps1 (Bedienung). Kein Docker, kein Substrat, keine Kosten; arbeitet nur in einem Temp-Ordner.
# Usage:  .\scripts\dev\substrate_reservation_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
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
Assert-That 'freigeben: Treffer' (Remove-SlotReservation -File $file -Container 'sub-a')
Assert-That 'freigeben: nur der eine weg' ((@(Read-SlotReservations -File $file -Now $t0.AddMinutes(10)) | ForEach-Object Container) -join ',' -eq 'sub-b')
Assert-That 'freigeben: unbekannter Container = kein Treffer' (-not (Remove-SlotReservation -File $file -Container 'gibt-es-nicht'))
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
$o = Invoke-Cli @()
Assert-That 'ohne Parameter: Fehler mit Usage' ($o.Code -ne 0)

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "substrate_reservation_test: $failed Fehler."
exit $failed
