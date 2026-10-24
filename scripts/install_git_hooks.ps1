#Requires -Version 5.1
# Installiert die Git-Hooks via prek (Rust-Binary, kein Python). Einmal nach dem Clone:
#   winget install --id j178.Prek      # Runner einmalig installieren
#   .\scripts\install_git_hooks.ps1     # Hooks in .git/hooks verdrahten
#
# prek liest .pre-commit-config.yaml (die Single-Source der Durchsetzung). Stages:
#   pre-commit  = deterministische Domaenen-Linter (doc/config/workflow/contract/catalog/fn) + Hygiene
#   pre-push    = LAN/live + langsam (db_test/infra_test) + LLM-Suiten-Empfehlung
#   commit-msg  = Conventional Commits
# Notfall-Bypass: git commit/push --no-verify (bewusst, nicht zur Gewohnheit).

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\lib\devenv.ps1"

# prek finden (geteilte 3-stufige Aufloesung: PATH -> winget-Links-Shim -> Packages-Scan).
$prek = Resolve-Prek
if (-not $prek) {
    throw "prek nicht gefunden. Erst installieren:  winget install --id j178.Prek  (dann Shell neu starten) -- oder scripts/setup_dev_env.ps1."
}

Push-Location $RepoRoot
try {
    # --overwrite entfernt Alt-/Legacy-Hooks (sonst laeuft prek den alten pre-push ZUSAETZLICH mit).
    & $prek install --overwrite --hook-type pre-commit --hook-type pre-push --hook-type commit-msg
    if ($LASTEXITCODE -ne 0) { throw "prek install fehlgeschlagen (Exit $LASTEXITCODE)." }
} finally {
    Pop-Location
}

Write-Host "Installiert: pre-commit + pre-push + commit-msg Hooks via prek." -ForegroundColor Green
Write-Host "Voll-Lauf jederzeit: prek run --all-files . Notfall-Bypass: git push --no-verify." -ForegroundColor Cyan
