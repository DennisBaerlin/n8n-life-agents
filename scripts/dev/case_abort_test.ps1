#Requires -Version 5.1
# Selbsttest der Fall-Abbruch-Helfer in scripts/dev/test_n8n_state.ps1 (Write-CaseAbort, Test-ForceAbort, ...). Kein Substrat, keine Kosten.
# Schwarzkasten: ein Wegwerf-Treiber mit erfundenen Faellen laedt die Bibliothek per Dot-Sourcing wie ein echtes Testskript und laeuft als
# KINDPROZESS; geprueft werden Exit-Code und Ausgabe. So ist belegt statt vermutet, dass der Zaehler nicht in einer Kopie verloren geht
# und dass $script: aus der Bibliothek im Treiber ankommt (ein verlorenes $failed++ waere ein stiller Falsch-Gruen-Lauf).
# Usage:  .\scripts\dev\case_abort_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$lib = Join-Path $repo 'scripts\dev\test_n8n_state.ps1'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("case_abort_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $sandbox | Out-Null
$driver = Join-Path $sandbox 'driver.ps1'

# Wegwerf-Treiber: drei Faelle, Verhalten des zweiten per -Mode. Zaehlen, try/catch und Schlusszeile wie in den echten Treibern.
$driverText = @'
param([string]$Lib, [string]$Mode = 'none', [string]$ForceAbortId)
$ErrorActionPreference = 'Stop'
. $Lib
$failed = 0; $passed = 0
$ids = @('c1', 'c2', 'c3')
foreach ($id in $ids) {
    try {
        Test-ForceAbort $id $ForceAbortId
        Write-Host "  [$id] Fall"
        if ($id -eq 'c2') {
            switch ($Mode) {
                'plain'   { throw 'kaputt im Fall' }
                { $_ -in 'regex', 'regexnoid' } { throw 'Regular expression execution timed out' }
                'json'    {
                    $er = New-Object System.Management.Automation.ErrorRecord ((New-Object System.Exception 'roh'), 'x', 'NotSpecified', $null)
                    $er.ErrorDetails = New-Object System.Management.Automation.ErrorDetails '{"message":"Detailtext aus JSON"}'
                    throw $er
                }
                'long'    { throw ('x' * 500) }
                'cleanup' { throw 'kaputt im Fall' }
            }
        }
        $passed++
    } catch {
        $failed++
        Write-CaseAbort -ErrorRecord $_ -CaseId $id -NoIdParam:($Mode -eq 'regexnoid') -Cleanup {
            Write-Host 'CLEANUP-LAUF'
            if ($Mode -eq 'cleanup') { throw 'Aufraeumen kaputt' }
        }
    }
}
Write-AbortedCases
$failed += Assert-ForceAbortFired $ForceAbortId
Write-Host "$passed/$($ids.Count) Faelle bestanden, $failed fehlgeschlagen."
exit $failed
'@
[System.IO.File]::WriteAllText($driver, $driverText, (New-Object System.Text.UTF8Encoding($true)))

function Invoke-Driver([string]$Mode, [string]$ForceAbortId = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $extra = if ($ForceAbortId) { " -ForceAbortId $ForceAbortId" } else { '' }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$driver`" -Lib `"$lib`" -Mode $Mode$extra"
    $psi.WorkingDirectory = $repo
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $errTask.Result; Lines = @($out -split "`r?`n" | Where-Object { $_.Trim() }) }
}

$failed = 0
function Assert-That([string]$Label, [bool]$Cond, $Run) {
    if ($Cond) { Write-Host "  [PASS] $Label" -ForegroundColor Green; return }
    $script:failed++
    Write-Host "  [FAIL] $Label" -ForegroundColor Red
    if ($Run) { Write-Host "    exit=$($Run.Exit)`n$($Run.Out)$($Run.Err)" -ForegroundColor DarkGray }
}

try {
    Write-Host "case_abort_test (Fall-Abbruch-Helfer als Kindprozess)"

    $r = Invoke-Driver 'none'
    Assert-That 'gruener Lauf: Exit 0, keine Abbruch-Zeile, Schlusszeile 3/3' ($r.Exit -eq 0 -and $r.Out -notmatch 'Abbruch|Abgebrochen' -and $r.Lines[-1] -eq '3/3 Faelle bestanden, 0 fehlgeschlagen.') $r

    $r = Invoke-Driver 'plain'
    $abortLine = @($r.Lines | Where-Object { $_ -match '\[FAIL\] Abbruch: kaputt im Fall \(Skriptzeile \d+\)' })
    Assert-That 'Ausnahme im 2. Fall: Exit 1 (Zaehler kommt im Treiber an)' ($r.Exit -eq 1) $r
    Assert-That 'Abbruch-Zeile mit Grund und Skriptzeile' ($abortLine.Count -eq 1) $r
    Assert-That 'Lauf geht weiter: 3. Fall laeuft' ($r.Out -match '\[c3\] Fall') $r
    Assert-That 'Schlusszeile 2/3, 1 fehlgeschlagen' ($r.Lines[-1] -eq '2/3 Faelle bestanden, 1 fehlgeschlagen.') $r
    Assert-That 'abgebrochene Faelle namentlich, vor der Schlusszeile' ($r.Lines[-2] -match 'Abgebrochen \(Ausnahme statt Pruefung\): c2$') $r
    Assert-That 'Aufraeumen genau einmal' (@($r.Lines | Where-Object { $_ -eq 'CLEANUP-LAUF' }).Count -eq 1) $r
    Assert-That 'kein Zeitschutz-Hinweis bei gewoehnlicher Ausnahme' ($r.Out -notmatch 'Zeitschutz') $r

    $r = Invoke-Driver 'regex'
    Assert-That 'Zeitschutz-Text: Hinweis mit -Id' ($r.Out -match 'n8n-Zeitschutz.*Einzeln wiederholen: -Id c2') $r
    $r = Invoke-Driver 'regexnoid'
    Assert-That 'ohne -Id-Parameter: Hinweis "Lauf wiederholen"' ($r.Out -match 'n8n-Zeitschutz.*Lauf wiederholen\.' -and $r.Out -notmatch '-Id c2') $r

    $r = Invoke-Driver 'json'
    Assert-That 'ErrorDetails mit JSON-message: der Text daraus ist der Grund' ($r.Out -match 'Abbruch: Detailtext aus JSON \(Skriptzeile') $r

    $r = Invoke-Driver 'long'
    $longLine = @($r.Lines | Where-Object { $_ -match 'Abbruch: x+ \.\.\. \(Skriptzeile' })
    Assert-That 'langer Grund wird auf 300 Zeichen gekuerzt' ($longLine.Count -eq 1 -and $longLine[0] -notmatch 'x{301}') $r

    $r = Invoke-Driver 'cleanup'
    Assert-That 'Aufraeumen wirft selbst: Meldung, Lauf geht weiter, Exit 1' ($r.Exit -eq 1 -and $r.Out -match 'Aufraeumen nach dem Abbruch unvollstaendig: Aufraeumen kaputt' -and $r.Out -match '\[c3\] Fall' -and $r.Lines[-1] -eq '2/3 Faelle bestanden, 1 fehlgeschlagen.') $r

    $r = Invoke-Driver 'none' 'c2'
    Assert-That '-ForceAbortId c2: nur dieser Fall rot, Exit 1, Folgefall laeuft' ($r.Exit -eq 1 -and $r.Out -match 'Abbruch: Erzwungener Abbruch \(-ForceAbortId c2\)' -and $r.Out -match '\[c3\] Fall' -and $r.Lines[-1] -eq '2/3 Faelle bestanden, 1 fehlgeschlagen.') $r

    $r = Invoke-Driver 'none' 'gibtesnicht'
    Assert-That '-ForceAbortId nie erreicht: Lauf wird rot' ($r.Exit -eq 1 -and $r.Out -match 'gibtesnicht wurde in diesem Lauf nie erreicht' -and $r.Out -notmatch 'Abbruch:') $r
} finally {
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failed -eq 0) { Write-Host "case_abort_test: alle Pruefungen bestanden." -ForegroundColor Green }
else { Write-Host "case_abort_test: $failed Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $failed
