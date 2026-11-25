#Requires -Version 5.1
# session_stall_check_test.ps1 -- prueft scripts/dev/session_stall_check.ps1 gegen erfundene Transkripte in einem
# Wegwerf-Ordner: eine Session haengt an einem Werkzeug-Aufruf ohne Ergebnis (alt), eine ist frisch, eine ist alt,
# aber ohne offenen Aufruf (ruht nur; ein frueher abgelehnter Aufruf ohne Ergebnis und die Aufruf-Kopie einer api-request-blob-Zeile zaehlen nicht), eine haengt in einem laengst geloeschten Worktree. Nur die erste darf als STEHT
# gemeldet werden.
# Usage: .\scripts\dev\session_stall_check_test.ps1   Exit-Code = Anzahl roter Faelle.
$ErrorActionPreference = 'Stop'
$failed = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ("stall_test_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$prefix = 'C--fake-repo'
function New-Transcript([string]$name, [string[]]$lines, [int]$ageMin) {
    $d = Join-Path $root "$prefix--claude-worktrees-$name"
    New-Item -ItemType Directory -Force $d | Out-Null
    $f = Join-Path $d 'aaaa.jsonl'
    [IO.File]::WriteAllLines($f, $lines)
    (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-$ageMin)
}
$use = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__Claude_Browser__preview_start","input":{}}]}}'
$res = '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
$old = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t0","name":"Edit","input":{}}]}}'
$blob = '{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t9","name":"SendMessage","input":{}}]}}'
$txt = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fertig"}]}}'
try {
    New-Transcript 'haengt' @($use) 120
    New-Transcript 'frisch' @($use) 1
    New-Transcript 'ruht' @($old, $use, $res, $blob, $txt) 600

    $out = & (Join-Path $PSScriptRoot 'session_stall_check.ps1') -ProjectsRoot $root -RepoPrefix $prefix -WorktreeNames 'haengt', 'frisch', 'ruht' -StallMinutes 30 6>&1 | Out-String
    $rc = $LASTEXITCODE
    $cases = @(
        @{ n = 'exit_eins';           ok = ($rc -eq 1) }
        @{ n = 'haengt_gemeldet';     ok = ($out -match 'STEHT\s+haengt.*preview_start') }
        @{ n = 'frisch_nicht_steht';  ok = ($out -notmatch 'STEHT\s+frisch') }
        @{ n = 'ruht_nicht_steht';    ok = ($out -notmatch 'STEHT\s+ruht') }
        @{ n = 'geloescht_ignoriert'; ok = ($out -notmatch 'geloescht') }
    )
    foreach ($c in $cases) {
        if ($c.ok) { Write-Host "[PASS] $($c.n)" } else { Write-Host "[FAIL] $($c.n)"; $failed++ }
    }
    if ($failed) { Write-Host "Ausgabe (rc=$rc):"; Write-Host $out }
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
exit $failed
