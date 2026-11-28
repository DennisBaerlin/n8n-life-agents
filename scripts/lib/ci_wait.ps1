# ci_wait.ps1 -- Urteil des Warte-Modus von scripts/check_ci_status.ps1 (-Wait), getrennt vom Netz-Abruf, damit
# scripts/dev/ci_wait_test.ps1 es an erfundenen Lauf-Listen pruefen kann. Dot-sourcen.

# Teil-Lauf: ein Handstart mit Suiten-Auswahl (free-gates.yml setzt den run-name "free-gates [Auswahl] ...") prueft nicht den
# ganzen Stand und zaehlt darum nie als Lauf des Workflows, weder gruen noch rot. Nur workflow_dispatch und Titel-Anfang: ein
# PR-Titel oder eine Commit-Message mit demselben Wort bleibt ein voller Lauf.
function Test-CiPartialRun($Run) {
    "$($Run.event)" -eq 'workflow_dispatch' -and "$($Run.display_title)".StartsWith('free-gates [Auswahl]', [StringComparison]::Ordinal)
}

# Juengster Lauf des Workflows auf dem Stand entscheidet: ein neuer Anlauf nach Rot gilt, der alte rote Lauf nicht.
# verdict: green | red | pending | none (kein Lauf dieses Workflows auf diesem Stand).
function Get-CiWaitVerdict {
    param([object[]]$Runs, [Parameter(Mandatory)][string]$Workflow, [Parameter(Mandatory)][string]$Sha)
    $mine = @($Runs | Where-Object {
            $_ -and ("$($_.name)" -eq $Workflow -or "$($_.path)" -like "*/$Workflow.yml") -and "$($_.head_sha)".StartsWith($Sha, [StringComparison]::OrdinalIgnoreCase) -and -not (Test-CiPartialRun $_)
        } | Sort-Object { [datetime]$_.created_at } -Descending)
    if ($mine.Count -eq 0) { return [pscustomobject]@{ verdict = 'none'; run = $null } }
    $run = $mine[0]
    if ("$($run.status)" -ne 'completed') { return [pscustomobject]@{ verdict = 'pending'; run = $run } }
    # Gruen ist nur success, wie in Get-PinParentProblems (main_push.ps1): ein uebersprungener oder neutraler Lauf hat den Stand nicht geprueft.
    $ok = "$($run.conclusion)" -eq 'success'
    return [pscustomobject]@{ verdict = $(if ($ok) { 'green' } else { 'red' }); run = $run }
}

# Get-CiLatestMainRuns <Laeufe> -> je Workflow-Datei @{ Workflow; Run; Ok }: der juengste abgeschlossene Lauf auf main (release: auf
# einem Tag v*), ohne Teil-Laeufe. Gruppiert nach der Datei (path), nicht nach name: mit run-name im Workflow traegt name den Titel
# des Laufs, und der Lauf fiele aus seiner Gruppe. Ok auch bei skipped/neutral: die Ampel meldet Rot, nicht "nicht geprueft".
function Get-CiLatestMainRuns([object[]]$Runs) {
    foreach ($g in (@($Runs) | Where-Object { $_ -and "$($_.path)" -like '.github/workflows/*' } | Group-Object path)) {
        $wf = [System.IO.Path]::GetFileNameWithoutExtension($g.Name)
        $latest = $g.Group | Where-Object {
                "$($_.status)" -eq 'completed' -and -not (Test-CiPartialRun $_) -and ("$($_.head_branch)" -eq 'main' -or ($wf -eq 'release' -and "$($_.head_branch)" -like 'v*'))
            } | Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 1
        if ($latest) { [pscustomobject]@{ Workflow = $wf; Run = $latest; Ok = ("$($latest.conclusion)" -in @('success', 'skipped', 'neutral')) } }
    }
}

# Lauf-Nummer als [long] formatiert: als Gleitkommazahl gelesen stuende sie in Exponenten-Schreibweise im Text.
function Format-CiWaitLine {
    param($Verdict)
    if (-not $Verdict.run) { return "$($Verdict.verdict): kein Lauf gefunden" }
    $r = $Verdict.run
    return ('{0}: {1} Run {2} ({3}{4}) {5}' -f $Verdict.verdict, $r.name, ([long]$r.id).ToString(), $r.status,
        $(if ($r.conclusion) { "/$($r.conclusion)" } else { '' }), $r.html_url)
}

function Get-CiWaitExitCode {
    param([string]$Verdict)
    switch ($Verdict) { 'green' { return 0 } 'red' { return 1 } default { return 2 } }
}
