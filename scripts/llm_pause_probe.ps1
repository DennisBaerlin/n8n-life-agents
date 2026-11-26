#Requires -Version 5.1
# llm_pause_probe.ps1 -- bezahlte Mini-Probe der KI-Pause (nur im Owner-Fenster): eine echte Anfrage an Anthropic durch den
# installierten Gateway-Code im Test-Substrat (Modell claude-haiku-5-5, max_tokens 1; Kosten weit unter 1 Cent).
# Prueft den Erfolgsweg der Nachschau gegen die echte API: Status 200 mit content, /__llm_status.last_ok_at gesetzt, usage-Zeile
# ohne err. Die Ablehnungswege prueft gratis scripts/dev/llm_gateway_test.ps1 (Fall p: aufgezeichnete Anthropic-Antworten,
# Fall h: echte 401 mit erfundenem Schluessel).
# Voraussetzung: laufendes Substrat (scripts/dev/bootstrap_test_n8n.ps1, eigener Container ueber $env:N8NTEST_CONTAINER),
# TEST_ANTHROPIC_API_KEY in der .env. Eigene transiente Einheit n8ntest-gwt-probe auf 127.0.0.1:8106, danach gestoppt.
# Usage:  .\scripts\llm_pause_probe.ps1
# Exit-Code: 0 = Erfolgsweg bestaetigt; 1 = Fehler (Meldung nennt den Grund, nie den Schluessel).
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\dev\test_n8n_state.ps1"
. "$PSScriptRoot\lib\dotenv.ps1"
. "$PSScriptRoot\lib\test_common.ps1"

$conn = Get-TestN8nConnection
$Container = $conn.Container
$Unit = 'n8ntest-gwt-probe'
$Port = 8106
$GwJs = '/usr/local/lib/lifeagents-llm-gateway/server.js'

$line = Read-DotEnvLines (Join-Path $RepoRoot '.env') | Where-Object { $_ -match '^\s*TEST_ANTHROPIC_API_KEY=' } | Select-Object -First 1
$key = if ($line) { ($line -split '=', 2)[1].Trim() } else { '' }
if (-not $key -or $key -eq 'ci-dummy-key') { Write-Host 'TEST_ANTHROPIC_API_KEY fehlt in der .env.' -ForegroundColor Red; exit 1 }

function Invoke-InC([string[]]$CmdArgs) { Invoke-Native docker (@('exec', $Container) + $CmdArgs) }
$nodeBin = ((Invoke-InC @('sh', '-c', 'command -v node')).Output -join '').Trim()
Invoke-InC @('systemctl', 'stop', $Unit) | Out-Null
Invoke-InC @('systemctl', 'reset-failed', $Unit) | Out-Null
$r = Invoke-InC @('systemd-run', "--unit=$Unit", '--collect', "--setenv=LLM_GATEWAY_PORT=$Port", '--setenv=LLM_GATEWAY_KEEPALIVE_HOURS=0', $nodeBin, $GwJs)
if ($r.Code -ne 0) { Write-Host "Gateway-Einheit startet nicht: $($r.Output -join ' ')" -ForegroundColor Red; exit 1 }
$ok = $false
try {
    for ($i = 0; $i -lt 25; $i++) {
        if ((((Invoke-InC @('sh', '-c', "curl -sf http://127.0.0.1:$Port/__health >/dev/null && echo ok || echo no")).Output -join '').Trim()) -eq 'ok') { break }
        Start-Sleep -Milliseconds 300
    }
    $body = '{"model":"claude-haiku-5-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
    $hostFile = Join-Path $env:TEMP 'llm_pause_probe_req.json'
    [System.IO.File]::WriteAllText($hostFile, $body, $Utf8NoBom)
    Invoke-Native docker @('cp', $hostFile, "${Container}:/tmp/llm_pause_probe_req.json") | Out-Null
    Remove-Item $hostFile -ErrorAction SilentlyContinue
    # Schluessel per curl-Config auf stdin (nie im argv).
    $cfg = "header = `"x-api-key: $key`"`nheader = `"anthropic-version: 2023-06-01`"`nheader = `"content-type: application/json`"`n"
    $res = Invoke-Native docker @('exec', '-i', $Container, 'curl', '-s', '-K', '-', '-m', '60', '-o', '/tmp/llm_pause_probe_resp', '-w', '%{http_code}',
        '-X', 'POST', "http://127.0.0.1:$Port/v1/messages", '--data-binary', '@/tmp/llm_pause_probe_req.json') -StdIn $cfg
    $status = (($res.Output -join '').Trim())
    $resp = $null; try { $resp = ((Invoke-InC @('cat', '/tmp/llm_pause_probe_resp')).Output -join "`n") | ConvertFrom-Json } catch { }
    $st = $null; try { $st = ((Invoke-InC @('curl', '-s', "http://127.0.0.1:$Port/__llm_status")).Output -join '') | ConvertFrom-Json } catch { }
    $usage = @((Invoke-InC @('journalctl', '-u', $Unit, '-o', 'cat', '--no-pager')).Output | Where-Object { $_ -match '"ev":"usage"' }) | Select-Object -Last 1
    $u = $null; try { $u = $usage | ConvertFrom-Json } catch { }
    $ok = ($status -eq '200') -and $resp -and ($resp.content -is [array]) -and $st -and $st.last_ok_at -and $u -and ($null -eq $u.err)
    $tok = if ($u) { "Eingabe $($u.input_tokens), Ausgabe $($u.output_tokens) Tokens" } else { 'Verbrauch unbekannt' }
    if ($ok) { Write-Host "OK: echte Anfrage 200, Nachschau-Erfolg erkannt (last_ok_at gesetzt, kein err) - $tok." -ForegroundColor Green }
    else { Write-Host "FEHLER: Status=$status content=$([bool]($resp.content)) last_ok_at=$($st.last_ok_at) err=$($u.err)" -ForegroundColor Red }
} finally {
    Invoke-InC @('rm', '-f', '/tmp/llm_pause_probe_req.json', '/tmp/llm_pause_probe_resp') | Out-Null
    Invoke-InC @('systemctl', 'stop', $Unit) | Out-Null
}
if ($ok) { exit 0 } else { exit 1 }
