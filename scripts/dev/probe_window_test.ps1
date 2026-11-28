#Requires -Version 5.1
# probe_window_test.ps1 -- Regressionstest des Zeitfensters der Waechter-Probe (scripts/lib/probe_window.ps1): das Fenster 'outside'
# wird erst nach dem Warten auf eine sichere Minute berechnet, sonst liegt der Lauf nach einem Stundenwechsel im Fenster.
# Die Uhr, das Schlafen und die Datenbank-Stunde werden eingespeist; kein Warten, kein Substrat, kein Netz.
# Usage:  .\scripts\dev\probe_window_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\probe_window.ps1')
$failed = 0
function Assert-True([string]$Name, [bool]$Ok, [string]$Got = '') {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name $Got" -ForegroundColor Red; $script:failed++ }
}

# Eingespeiste Uhr: jede Schlaf-Runde schiebt sie um 5 Sekunden weiter.
function New-FakeClock([datetime]$Start) { return [pscustomobject]@{ Time = $Start; Sleeps = 0 } }
function Invoke-Window($Clock, [string]$Mode) {
    return Get-RunWindow -Mode $Mode -Now { $Clock.Time }.GetNewClosure() `
        -Sleep { $Clock.Time = $Clock.Time.AddSeconds(5); $Clock.Sleeps++ }.GetNewClosure() `
        -HourNow { $Clock.Time.Hour }.GetNewClosure()
}

Write-Host 'Fenster aus der Stunde:'
$w = Get-WindowHours 'inside' 14
Assert-True 'inside: ganzer Tag' ($w.From -eq 0 -and $w.Until -eq 24) "$($w.From)-$($w.Until)"
$w = Get-WindowHours 'outside' 14
Assert-True 'outside: ab der naechsten Stunde' ($w.From -eq 15 -and $w.Until -eq 24) "$($w.From)-$($w.Until)"
$w = Get-WindowHours 'outside' 23
Assert-True 'outside um 23 Uhr: 0 bis 23' ($w.From -eq 0 -and $w.Until -eq 23) "$($w.From)-$($w.Until)"

Write-Host 'Sichere Minute:'
foreach ($m in 9, 10, 11, 59, 0) { Assert-True "Minute $m unsicher" (Test-UnsafeMinute $m) }
foreach ($m in 1, 8, 12, 30, 58) { Assert-True "Minute $m sicher" (-not (Test-UnsafeMinute $m)) }

Write-Host 'Stundenwechsel waehrend des Wartens:'
$c = New-FakeClock ([datetime]'2026-01-01T10:59:30')
$w = Invoke-Window $c 'outside'
Assert-True 'Uhr steht danach in Stunde 11' ($c.Time.Hour -eq 11 -and $c.Time.Minute -eq 1) "$($c.Time)"
Assert-True 'outside rechnet die Stunde NACH dem Warten (12 bis 24, nicht 11 bis 24)' ($w.From -eq 12 -and $w.Until -eq 24) "$($w.From)-$($w.Until)"
Assert-True 'der Lauf um 11:01 liegt ausserhalb des Fensters' (11 -lt $w.From)

$c = New-FakeClock ([datetime]'2026-01-01T22:59:30')
$w = Invoke-Window $c 'outside'
Assert-True 'Wechsel 22 nach 23 Uhr: Fenster 0 bis 23 (Stunde 23, nicht 22)' ($w.From -eq 0 -and $w.Until -eq 23) "$($w.From)-$($w.Until)"
Assert-True 'Stunde 23 liegt ausserhalb von 0 bis 23' (23 -ge $w.Until)

Write-Host 'Kein Warten noetig:'
$c = New-FakeClock ([datetime]'2026-01-01T14:30:00')
$w = Invoke-Window $c 'outside'
Assert-True 'sichere Minute: kein Schlafen, Fenster 15 bis 24' ($c.Sleeps -eq 0 -and $w.From -eq 15 -and $w.Until -eq 24) "Schlafen $($c.Sleeps), $($w.From)-$($w.Until)"
$c = New-FakeClock ([datetime]'2026-01-01T10:59:30')
$w = Invoke-Window $c 'inside'
Assert-True 'inside bleibt 0 bis 24, auch nach dem Wechsel' ($w.From -eq 0 -and $w.Until -eq 24) "$($w.From)-$($w.Until)"
$c = New-FakeClock ([datetime]'2026-01-01T09:00:00')
$null = Invoke-Window $c 'inside'
Assert-True 'Minute 0 wird abgewartet, Lauf startet in Minute 1' ($c.Time.Minute -eq 1 -and $c.Sleeps -gt 0) "$($c.Time)"

Write-Host "probe_window_test: $failed Fehler."
exit $failed
