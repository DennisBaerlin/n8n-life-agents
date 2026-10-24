#Requires -Version 5.1
# check_ci_status.ps1 — CI-Ampel: ist der letzte Lauf jedes GitHub-Workflows auf main (Release: der letzte Tag-Lauf)
# gruen? Anlass 2026-10-22: workflow_lint war ~20 Pushes lang nur in der CI rot (lokal uebersprungen), keine Session
# hat es gemerkt. Genutzt vom SessionStart-Hook .claude/hooks/check_ci_status.ps1 (-Hook: knapper Kontext-Text,
# still bei gruen/Fehler) und manuell. Read-only gegen die GitHub-API; Token aus dem Git-Credential-Store (GCM,
# derselbe Weg wie git push), nie interaktiv. Exit-Code = Anzahl roter Workflows (Fehler beim Abfragen -> 0 + Hinweis).
#
# Usage:  .\scripts\check_ci_status.ps1 [-Hook]
param([switch]$Hook)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-GitHubToken {
    $env:GCM_INTERACTIVE = 'never'; $env:GIT_TERMINAL_PROMPT = '0'
    # Eingabe ueber eine Datei-Umleitung: das PS-5.1-Pipe an ein natives Programm verfaelscht die erste Zeile
    # (git: "missing protocol field").
    $f = Join-Path $env:TEMP ('gcf_' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [System.IO.File]::WriteAllText($f, "protocol=https`nhost=github.com`n`n", (New-Object System.Text.UTF8Encoding($false)))
        $cred = cmd /c "git credential fill < `"$f`" 2>nul"
    } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    $line = @($cred) | Where-Object { $_ -like 'password=*' } | Select-Object -First 1
    if ($line) { return $line.Substring(9) }
    return $null
}

try {
    $remote = (git -C $PSScriptRoot remote get-url origin).Trim()
    if ($remote -notmatch 'github\.com[:/]([^/]+)/([^/.]+)') { throw "kein GitHub-Remote: $remote" }
    $slug = "$($Matches[1])/$($Matches[2])"
    $tok = Get-GitHubToken
    if (-not $tok) { throw 'kein GitHub-Token im Git-Credential-Store' }
    $runs = (Invoke-RestMethod -Uri "https://api.github.com/repos/$slug/actions/runs?per_page=60" -TimeoutSec 8 `
        -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'lifeagents-ci-check' }).workflow_runs
} catch {
    if (-not $Hook) { Write-Host "CI-Status nicht abrufbar: $($_.Exception.Message)" -ForegroundColor Yellow }
    exit 0
}

# Je Workflow der juengste abgeschlossene Lauf: Push-Workflows auf main, release auf einem Tag (v*).
$red = @()
foreach ($g in ($runs | Where-Object { "$($_.path)" -like '.github/workflows/*' } | Group-Object name)) {   # ohne Dependabot-Hintergrundlaeufe
    $latest = $g.Group | Where-Object { $_.status -eq 'completed' -and ($_.head_branch -eq 'main' -or ($_.name -eq 'release' -and $_.head_branch -like 'v*')) } |
        Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 1
    if (-not $latest) { continue }
    $ok = $latest.conclusion -in @('success', 'skipped', 'neutral')
    if (-not $Hook) {
        $c = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("{0,-12} {1,-9} {2} {3}  {4}" -f $g.Name, $latest.conclusion, $latest.head_sha.Substring(0, 7), ([datetime]$latest.created_at).ToLocalTime().ToString('dd.MM. HH:mm'), $latest.display_title) -ForegroundColor $c
    }
    if (-not $ok) { $red += $latest }
}

if ($Hook -and $red.Count) {
    $parts = $red | ForEach-Object { "$($_.name) ($($_.conclusion), $($_.head_sha.Substring(0,7)) '$($_.display_title)', Run $($_.id))" }
    $ctx = 'CI ROT auf GitHub: ' + ($parts -join '; ') + '. Zuerst die Ursache klaeren und beheben, bevor neue Arbeit gepusht wird ' +
           '(Logs: gh run view <Run> --log-failed, GH_TOKEN aus git credential fill). Dem Owner in einem Satz melden.'
    Write-Output (@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5)
}
exit $red.Count
