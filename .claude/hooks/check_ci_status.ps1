# SessionStart-Hook: CI-Ampel. Ist der letzte GitHub-Lauf eines Workflows auf main (Release: letzter Tag) rot,
# bekommt die Session den Auftrag, das zuerst zu klaeren (scripts/check_ci_status.ps1 -Hook). Gruen, offline oder
# ohne Token -> still. Nie ein Fehler-Exit (eine Session darf am Hook nie scheitern). ASCII-only.
try {
    $repo = (git rev-parse --show-toplevel 2>$null)
    if (-not $repo) { exit 0 }
    $script = Join-Path "$repo".Trim() 'scripts/check_ci_status.ps1'
    if (-not (Test-Path $script)) { exit 0 }
    & $script -Hook
} catch { }
exit 0
