# n8ntest_state_file.ps1 -- die eine Adresse der Zustandsdatei des Test-Substrats (URL der socat-Bruecke, API-Schluessel, mock_*):
# .local/n8ntest_state.<container>.json im Haupt-Checkout, je Container eine Datei (Container = $env:N8NTEST_CONTAINER, sonst der
# Bootstrap-Default). Die Datei gehoert zum Container, nicht zum Worktree: Laege sie im Worktree, laese ein zweiter Worktree
# gegen denselben Container einen alten Schluessel (401 Unauthorized); eine gemeinsame Datei fuer alle Container liesse ein zweites
# Substrat den Schluessel des ersten ueberschreiben (403). Jeder Leser und Schreiber holt den Pfad hier.
# Dot-sourcen; Test: scripts/dev/n8ntest_state_file_test.ps1.
function Get-TestN8nStateFile {
    param([string]$Container = $(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' }))
    # Haupt-Checkout = Elternordner des gemeinsamen .git; stimmt nicht bei Bare-Repo oder --separate-git-dir (hier nicht genutzt).
    $common = [string](& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)
    return (Join-Path (Split-Path $common -Parent) ".local\n8ntest_state.$Container.json")
}
