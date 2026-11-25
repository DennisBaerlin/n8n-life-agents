#Requires -Version 5.1
# session_stall_check.ps1 -- findet Unter-Sessions, die still auf eine Antwort im Desktop-Fenster warten.
# Die Session-Liste der App zeigt so eine Session als "running", und jede zugestellte Nachricht frischt
# lastActivityAt auf; beides taeugt nicht als Lebenszeichen. Belastbar ist das Transkript: Endet es mit einem
# Werkzeug-Aufruf ohne Ergebnis und wurde es seit -StallMinutes nicht mehr geschrieben, steht die Session
# (typisch: Freigabe-Abfrage, preview_start, die per Remote Control nicht sichtbar ist).
# Liest nur ~/.claude/projects/<Repo>--claude-worktrees-*/ (neuestes *.jsonl je Worktree), aendert nichts.
#
# Usage:  .\scripts\dev\session_stall_check.ps1 [-StallMinutes 30]
#         (-ProjectsRoot/-RepoPrefix/-WorktreeNames nur fuer den Test: scripts/dev/session_stall_check_test.ps1)
# Exit-Code = Anzahl stehender Sessions.
param([int]$StallMinutes = 30, [string]$ProjectsRoot, [string]$RepoPrefix, [string[]]$WorktreeNames, [int]$TailBytes = 1MB)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $ProjectsRoot) { $ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects' }
if (-not $RepoPrefix) {
    # Haupt-Checkout auch aus einem Worktree: --git-common-dir zeigt auf <Haupt-Checkout>\.git.
    $common = (git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim()
    $main = Split-Path -Parent $common
    # Claude Code benennt den Projektordner nach dem Pfad, jedes Nicht-Alphanumerische wird '-'.
    $RepoPrefix = ($main -replace '[^A-Za-z0-9]', '-')
}
if (-not $PSBoundParameters.ContainsKey('WorktreeNames')) {
    # Projektordner bleiben nach dem Loeschen eines Worktrees liegen; nur bestehende Worktrees zaehlen.
    $WorktreeNames = @(git -C $PSScriptRoot worktree list --porcelain | Where-Object { $_ -like 'worktree *' } |
        ForEach-Object { Split-Path -Leaf ($_.Substring(9)) })
}

# Liest nur das Dateiende (Transkripte werden zweistellige MB gross); die erste, angeschnittene Zeile faellt weg.
function Get-TailLines([string]$path, [long]$bytes) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $fs.Length - $bytes); $fs.Position = $start
        $buf = New-Object byte[] ($fs.Length - $start); [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    if ($start -gt 0) { $lines = $lines | Select-Object -Skip 1 }
    $lines
}

$stalled = 0
$dirs = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith("$RepoPrefix--claude-worktrees-", [StringComparison]::OrdinalIgnoreCase) -and
        $WorktreeNames -contains $_.Name.Substring($RepoPrefix.Length + '--claude-worktrees-'.Length) })
foreach ($d in $dirs) {
    $f = Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { continue }
    $name = $d.Name.Substring($RepoPrefix.Length + '--claude-worktrees-'.Length)
    $age = [int]((Get-Date) - $f.LastWriteTime).TotalMinutes
    $lastId = $null; $lastName = $null; $answered = $false
    foreach ($line in (Get-TailLines $f.FullName $TailBytes)) {
        try { $o = $line | ConvertFrom-Json } catch { continue }
        # Nur echte Gespraechszeilen; api-request-blob u. a. enthalten Kopien frueherer Aufrufe.
        if ($o.type -notin 'assistant', 'user' -or -not $o.message.content -or $o.message.content -is [string]) { continue }
        foreach ($c in @($o.message.content)) {
            if ($c.type -eq 'tool_use') { $lastId = $c.id; $lastName = $c.name; $answered = $false }
            elseif ($c.type -eq 'tool_result' -and $c.tool_use_id -eq $lastId) { $answered = $true }
        }
    }
    # Nur der letzte Aufruf zaehlt: abgelehnte oder abgebrochene aeltere Aufrufe bleiben im Transkript ohne Ergebnis
    # stehen, obwohl die Session danach weiterlief. Ein Hintergrund-Agent liefert sein Ergebnis sofort ("launched").
    $pending = if ($lastId -and -not $answered) { $lastName } else { '' }
    if ($pending -and $age -ge $StallMinutes) {
        $stalled++
        Write-Host ("STEHT   {0}  seit {1} min, wartet auf: {2}" -f $name, $age, $pending) -ForegroundColor Yellow
    } elseif ($pending) {
        Write-Host ("arbeitet {0}  vor {1} min, gerade: {2}" -f $name, $age, $pending)
    } else {
        Write-Host ("ruht    {0}  vor {1} min" -f $name, $age)
    }
}
exit $stalled
