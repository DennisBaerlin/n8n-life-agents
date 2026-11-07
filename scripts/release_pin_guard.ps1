#Requires -Version 5.1
# release_pin_guard.ps1 -- Sperre fuer Release-Tags (v*.*.*): der Pin des master-Images in provisioning/compose/compose.yml muss
# zum Release-Baum des Tags passen, sonst ist der Tag veroeffentlicht und nicht mehr verschiebbar (neue Patch-Version noetig).
# Pruefung ohne Register und ohne Docker: Test-MasterPinOffline (scripts/lib/release_images.ps1, dieselbe Herkunfts-Pruefung wie
# sign_release.ps1, nur mit dem Elternteil des Pin-Commits statt des Image-Labels). Release-Ablauf: docs/reference/provisioning.md
# *Docker-Verbund* (Auslieferung des master-Images).
# Aufrufer: .claude/hooks/dev_cycle_guard.ps1 (git tag v… und git push mit Tag) und prek pre-push (Hook release-pin).
# Gilt nur auf der Owner-Maschine (scripts/lib/owner_machine.ps1): Beitraege von aussen und CI taggen keine Releases.
# Usage:
#   .\scripts\release_pin_guard.ps1 -Tag v0.40.0 [-Commit <rev>]   beim Anlegen: Stand = -Commit, sonst HEAD
#   .\scripts\release_pin_guard.ps1 [-AllTags]                     beim Push: Ziel aus PRE_COMMIT_REMOTE_BRANCH/PRE_COMMIT_TO_REF;
#                                                                  -AllTags (git push --tags/--follow-tags/--all/--mirror)
#                                                                  zusaetzlich jeder lokale v*-Tag, der PRE_COMMIT_REMOTE_NAME fehlt
# Branch-Pushes prueft es nie. Exit 0 = frei oder kein Release-Tag, 1 = Pin passt nicht, 2 = nicht pruefbar.
param(
    [string]$Tag,
    [string]$Commit,
    [switch]$AllTags
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] Release-Pin nicht pruefbar: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'lib\owner_machine.ps1')
. (Join-Path $PSScriptRoot 'lib\release_images.ps1')
$ReleaseTagRx = '^v\d+\.\d+\.\d+'

if (-not (Test-OwnerMachine (Get-MainCheckoutRoot $RepoRoot))) {
    Write-Host '  [skip] keine Owner-Maschine -> keine Release-Pin-Pruefung' -ForegroundColor DarkGray
    exit 0
}

# Liste der zu pruefenden Tags als @{ Name; Rev }.
$todo = @()
if ($Tag) {
    if ($Tag -match $ReleaseTagRx) { $todo += @{ Name = $Tag; Rev = $(if ($Commit) { $Commit } else { 'HEAD' }) } }
} else {
    $dest = [string]$env:PRE_COMMIT_REMOTE_BRANCH
    $name = $dest -replace '^refs/tags/', ''
    $isTag = $dest -match '^refs/tags/' -or ([bool](& git -C $RepoRoot rev-parse -q --verify "refs/tags/$name") -and -not [bool](& git -C $RepoRoot rev-parse -q --verify "refs/heads/$name"))
    if ($isTag -and $name -match $ReleaseTagRx) {
        $rev = if ($env:PRE_COMMIT_TO_REF) { $env:PRE_COMMIT_TO_REF } else { "refs/tags/$name" }
        $todo += @{ Name = $name; Rev = $rev }
    }
    if ($AllTags) {
        $remote = if ($env:PRE_COMMIT_REMOTE_NAME) { $env:PRE_COMMIT_REMOTE_NAME } else { 'origin' }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $ls = @(& git -C $RepoRoot ls-remote --tags --refs $remote 2>$null) } finally { $ErrorActionPreference = $prev }
        if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] Remote '$remote' nicht lesbar (git ls-remote) -> Release-Tags nicht pruefbar" -ForegroundColor Red; exit 2 }
        $onRemote = @($ls | ForEach-Object { ($_ -split "`t")[-1] -replace '^refs/tags/', '' })
        foreach ($t in @(& git -C $RepoRoot tag -l 'v*')) {
            if ($t -match $ReleaseTagRx -and $onRemote -notcontains $t -and -not ($todo | Where-Object { $_.Name -eq $t })) { $todo += @{ Name = $t; Rev = "refs/tags/$t" } }
        }
    }
}

$bad = 0
foreach ($t in $todo) {
    $iss = Test-MasterPinOffline $RepoRoot $t.Rev
    if ($iss.Count -eq 0) { Write-Host "  [OK] $($t.Name): Pin des master-Images passt zum Release-Baum" -ForegroundColor Green; continue }
    $bad++
    $shown = (@($iss | Select-Object -First 3) -join ' / ') + $(if ($iss.Count -gt 3) { " (+$($iss.Count - 3) weitere)" } else { '' })
    Write-Host "  [FAIL] Release-Tag $($t.Name): master-Image-Pin passt nicht ($shown). Erst .\scripts\build_master_image.ps1 -Version $($t.Name), Pin-Commit, dann neu taggen (docs/reference/provisioning.md *Docker-Verbund*)" -ForegroundColor Red
}
exit $(if ($bad) { 1 } else { 0 })
