# github_runs.ps1 -- Lauf-Liste der GitHub-Workflows dieses Repos, read-only. Token aus dem Git-Credential-Store (GCM,
# derselbe Weg wie git push), nie interaktiv. Dot-sourcen. Nutzer: scripts/check_ci_status.ps1, scripts/main_push_guard.ps1.

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

function Get-WorkflowRuns([string]$Query) {
    $remote = (git -C $PSScriptRoot remote get-url origin).Trim()
    if ($remote -notmatch 'github\.com[:/]([^/]+)/([^/.]+)') { throw "kein GitHub-Remote: $remote" }
    $slug = "$($Matches[1])/$($Matches[2])"
    $tok = Get-GitHubToken
    if (-not $tok) { throw 'kein GitHub-Token im Git-Credential-Store' }
    return (Invoke-RestMethod -Uri "https://api.github.com/repos/$slug/actions/runs?$Query" -TimeoutSec 8 `
        -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'lifeagents-ci-check' }).workflow_runs
}
