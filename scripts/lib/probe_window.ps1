# probe_window.ps1 -- Zeitfenster der Waechter-Probe (scripts/dev/monitor_probe_test.ps1), getrennt von Substrat und Uhr, damit
# scripts/dev/probe_window_test.ps1 den Stundenwechsel mit eingespeister Uhr pruefen kann. Dot-sourcen.

# Minute 10 (echter Zeitplan des Cron) und der Stundenwechsel (Fenster-Grenze) sind fuer einen Lauf unsicher.
function Test-UnsafeMinute([int]$Minute) { return $Minute -in @(9, 10, 11, 59, 0) }

function Wait-SafeMinute([scriptblock]$Now = { Get-Date }, [scriptblock]$Sleep = { Start-Sleep -Seconds 5 }) {
    while (Test-UnsafeMinute ([int](& $Now).Minute)) { & $Sleep }
}

# Reminder-Fenster (core.config reminders_from/_until): 'inside' = ganzer Tag, 'outside' = alles nach der Stunde $Hour
# (ab 23 Uhr: 0 bis 23, die Stunde selbst bleibt draussen).
function Get-WindowHours([string]$Mode, [int]$Hour) {
    if ($Mode -ne 'outside') { return @{ From = 0; Until = 24 } }
    if ($Hour -ge 23) { return @{ From = 0; Until = 23 } }
    return @{ From = $Hour + 1; Until = 24 }
}

function Get-RunWindow {
    param([string]$Mode, [scriptblock]$Now = { Get-Date }, [scriptblock]$Sleep = { Start-Sleep -Seconds 5 }, [scriptblock]$HourNow)
    # Erst warten, dann die Stunde lesen: Das Warten kann ueber den Stundenwechsel gehen, eine vorher gelesene Stunde liegt dann daneben.
    Wait-SafeMinute -Now $Now -Sleep $Sleep
    return Get-WindowHours $Mode ([int](& $HourNow))
}
