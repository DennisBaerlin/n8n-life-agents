#Requires -Version 5.1
# update_chat_test.ps1 — DETERMINISTISCHER, GRATIS Test des Updates im Chat (Release-Karte, root-Runner, Fehler-Hilfe,
# Release-Signatur, Downgrade-Sperre) im laufenden Substrat — ohne GitHub, ohne echtes Telegram, ohne LLM.
#
# Ablauf: den Provisioning-Baum DIESES Checkouts in die Runtime des Containers spiegeln (/usr/local/lib/lifeagents/
# provisioning + die CLI /usr/local/bin/lifeagents neu rendern — genau das, was install_cli tut), den GitHub-Mock dazu
# kopieren und tests/mock_github/update_cases.sh fahren: Fake-Releases mit Stub-provision.sh (Ergebnis je Szenario),
# Telegram ueber den Mock (Aufzeichnung /tmp/mock_telegram.jsonl). Die echten Update-Timer des Substrats ruhen waehrend
# der Faelle; VERSION, Auftrags-/Latch-Zeilen und die Timer stellt der Fall-Runner am Ende zurueck.
# Voraussetzung: laufendes Substrat (bootstrap_test_n8n.ps1) + .\scripts\dev\enable_mock_telegram.ps1.
# Usage:  .\scripts\dev\update_chat_test.ps1 [-Port 8086] [-Verbose]   (belegt Port und Port+1; frei neben 8088 mock_llm,
#         8089 mock_telegram, 8090 llm_gateway, 8092 mock_paperless, 8093/8094 release_fetch, 8095-8099 + 8102/8103 llm_gateway_test)
# Exit-Code = Anzahl Fehler.
param([int]$Port = 8086, [switch]$Verbose)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
$TgPort = "$($state.mock_telegram.port)"
if (-not $TgPort) { $TgPort = '8089' }

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

Write-Host ""
Write-Host "Update im Chat (Karte, Runner, Fehler-Hilfe, Signatur) gegen Mock-GitHub + Mock-Telegram — Container $Container"
Write-Host ("-" * 64)

$root = '/opt/update_chat_test'
$lib = '/usr/local/lib/lifeagents'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\mock_github', 'mock_github'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}
# Runtime auf den Worktree-Stand (wie install_cli: Baum spiegeln + CLI aus lifeagents.tpl rendern).
$sync = "set -e; rm -rf $lib/provisioning && cp -a $root/provisioning $lib/provisioning && " +
        "sed 's|@@LIBDIR@@|$lib|g' $lib/provisioning/templates/lifeagents.tpl > /usr/local/bin/lifeagents && chmod 0755 /usr/local/bin/lifeagents"
$r = Invoke-Native docker @('exec', $Container, 'bash', '-c', $sync)
if ($r.Code -ne 0) { throw "Runtime-Spiegel im Container fehlgeschlagen: $($r.Output -join ' | ')" }

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_github/update_cases.sh", $root, "$Port", $TgPort)
$lines = @($r.Output)
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
if ($r.Code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] update_cases.sh brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
if ($passed -eq 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] update_cases.sh lieferte keine Faelle" -ForegroundColor Red }
Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "update_chat_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "update_chat_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
