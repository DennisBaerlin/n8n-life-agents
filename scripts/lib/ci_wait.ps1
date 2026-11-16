# ci_wait.ps1 -- Urteil des Warte-Modus von scripts/check_ci_status.ps1 (-Wait), getrennt vom Netz-Abruf, damit
# scripts/dev/ci_wait_test.ps1 es an erfundenen Lauf-Listen pruefen kann. Dot-sourcen.

# Juengster Lauf des Workflows auf dem Stand entscheidet: ein neuer Anlauf nach Rot gilt, der alte rote Lauf nicht.
# verdict: green | red | pending | none (kein Lauf dieses Workflows auf diesem Stand).
function Get-CiWaitVerdict {
    param([object[]]$Runs, [Parameter(Mandatory)][string]$Workflow, [Parameter(Mandatory)][string]$Sha)
    $mine = @($Runs | Where-Object {
            $_ -and ("$($_.name)" -eq $Workflow -or "$($_.path)" -like "*/$Workflow.yml") -and "$($_.head_sha)".StartsWith($Sha, [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object { [datetime]$_.created_at } -Descending)
    if ($mine.Count -eq 0) { return [pscustomobject]@{ verdict = 'none'; run = $null } }
    $run = $mine[0]
    if ("$($run.status)" -ne 'completed') { return [pscustomobject]@{ verdict = 'pending'; run = $run } }
    $ok = "$($run.conclusion)" -in @('success', 'skipped', 'neutral')
    return [pscustomobject]@{ verdict = $(if ($ok) { 'green' } else { 'red' }); run = $run }
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
