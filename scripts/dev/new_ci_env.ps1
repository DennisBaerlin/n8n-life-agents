#Requires -Version 5.1
# new_ci_env.ps1 - legt fuer .github/workflows/free-gates.yml eine .env aus erfundenen Werten an (Repo ist oeffentlich,
# der Workflow bekommt keine Secrets). Nur in CI: verweigert sich ohne $env:CI und ueberschreibt nie eine vorhandene .env,
# damit ein versehentlicher lokaler Aufruf die echte Datei nicht zerstoert.
# Owner = der fiktive Golden-Owner (Assert-GoldenHousehold in test_n8n_state.ps1).
# TEST_ANTHROPIC_API_KEY=ci-dummy-key: ohne Wert legt inject_credentials die Credential nicht an; llm_gateway_test
# ueberspringt bei genau diesem Wert seinen Fall gegen die echte API.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $env:CI) { throw 'new_ci_env.ps1 laeuft nur in CI ($env:CI fehlt).' }
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$target = Join-Path $RepoRoot '.env'
if (Test-Path $target) { throw ".env existiert schon: $target" }
$lines = @(
    'OWNER_CHAT_ID=1000001'
    "TEST_HARNESS_SECRET=$([guid]::NewGuid().ToString('N'))"
    "TEST_TELEGRAM_BOT_TOKEN=1000001:AA$([guid]::NewGuid().ToString('N'))"
    'TEST_TELEGRAM_CHAT_ID=1000001'
    'TEST_OWNER_FIRST_NAME=Erika'
    'TEST_OWNER_LAST_NAME=Mustermann'
    'TEST_OWNER_BIRTH_DATE=1980-05-20'
    'TEST_OWNER_LANGUAGE=de'
    'TEST_ANTHROPIC_API_KEY=ci-dummy-key'
    'TEST_GOOGLE_API_KEY=ci-dummy-key'
    'TEST_PAPERLESS_API_TOKEN=ci-dummy-token'
)
[System.IO.File]::WriteAllText($target, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
