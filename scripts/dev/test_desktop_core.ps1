#Requires -Version 5.1
# test_desktop_core.ps1 -- fuehrt die Tests der Start-App-Bibliothek (provisioning/desktop/core) in einem Wegwerf-Container
# aus. Grund: Auf dem Entwickler-Rechner ist kein Rust installiert, und die Bibliothek braucht weder Tauri noch ein
# Fenster (jeder Systembefehl laeuft ueber die Attrappe FakeHost). Die eigentliche App baut nur CI (desktop.yml).
#   .\scripts\dev\test_desktop_core.ps1                     alle Tests
#   .\scripts\dev\test_desktop_core.ps1 -Filter detect      nur Tests, deren Name 'detect' enthaelt
#   .\scripts\dev\test_desktop_core.ps1 -Lint               zusaetzlich cargo fmt --check und clippy -D warnings
# Container- und Volume-Namen pro Session: $env:DESKTOPTEST_PREFIX (Standard 'di6'); Volumes <prefix>-cargo/-target
# bleiben fuer schnelle Folgelaeufe stehen, Abbau mit -Down.
param([string]$Filter = '', [switch]$Lint, [switch]$Down)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$prefix = if ($env:DESKTOPTEST_PREFIX) { $env:DESKTOPTEST_PREFIX } else { 'di6' }
$image = 'rust:1-slim-bookworm'
if ($Down) {
    docker volume rm "$prefix-cargo" "$prefix-target" | Out-Null
    Write-Host "  [ok] Volumes $prefix-cargo/-target entfernt" -ForegroundColor Green
    exit 0
}
# Ganzes Repo nur lesend: Die Bibliothek liest den Textkatalog packages/core/locales/*.json beim Bau ein (texts.rs).
$src = (Resolve-Path $RepoRoot).Path
$cmd = "cargo test --quiet $Filter"
if ($Lint) { $cmd = "rustup component add rustfmt clippy >/dev/null 2>&1; cargo fmt --check && cargo clippy --all-targets --quiet -- -D warnings && $cmd" }
docker run --rm --name "$prefix-rust" -v "${src}:/repo:ro" -v "${prefix}-cargo:/usr/local/cargo/registry" -v "${prefix}-target:/target" `
    -e CARGO_TARGET_DIR=/target -w /repo/provisioning/desktop/core $image sh -c $cmd
exit $LASTEXITCODE
