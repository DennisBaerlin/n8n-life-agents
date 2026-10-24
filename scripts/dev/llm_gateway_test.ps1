#Requires -Version 5.1
# llm_gateway_test.ps1 -- GRATIS-Tier fuer den lokalen LLM-Gateway (provisioning/llm_gateway/server.js).
#
# Prueft die Gateway-Logik deterministisch IM laufenden Substrat (bootstrap_test_n8n.ps1), ohne den
# produktiven Gateway anzufassen: eigene transiente systemd-Units (Muster enable_mock_llm.ps1):
#   n8ntest-gwt-mock  = tests/mock_llm/server.js auf 127.0.0.1:8096 (Upstream-Stub, zeichnet `markers` auf)
#   n8ntest-gwt       = der installierte Gateway-Code auf 127.0.0.1:8095, Upstream = der Stub
#   n8ntest-gwt-dead  = Gateway auf 127.0.0.1:8097, Upstream = toter Port (Ausfallverhalten)
#   n8ntest-gwt-real  = Gateway auf 127.0.0.1:8098, Upstream = api.anthropic.com (nur Fall h, count_tokens = GRATIS)
#
# Faelle: (a) Agenten-Anfrage -> 3 Haltepunkte (Werkzeug+System 1h, oben 5m) · (b1) eigene Block-Marker -> keine
# statischen · (b2) nur oberer Marker -> statische trotzdem, oben unveraendert · (c) ohne eigene Werkzeuge (auch nur
# web_search) -> nichts eingefuegt · (d) Streaming durchgereicht + usage gemessen · (e) Upstream tot -> 502 + fester
# Fehlercode · (f) Kanarien-Text + Test-Schluessel nie im Journal (auch bei kaputtem JSON) · (g) 400 mit cache_control
# -> einmal ohne Einfuegen wiederholt (fallback) · (i) ungueltiges Anfrage-Ziel -> 400 ohne Absturz · (j) Agenten-Anfrage ->
# tool_choice auto + disable_parallel_tool_use, eigener Wert unveraendert · (k) Keep-Alive (eigene Unit, Takt 1,5 s):
# Agenten-Anfang mit max_tokens 0 angestupst, Einmal-Aufruf nicht gemerkt, KEEPALIVE_HOURS=0 = aus · (h) echter Upstream: POST /v1/messages/count_tokens (kostenlos)
# mit TEST_ANTHROPIC_API_KEY (fehlt er -> SKIP).
#
# Kein LLM-Credit (count_tokens ist laut Anthropic kostenlos). Exit = Anzahl FAIL.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# PS 5.1 stellt beim Pipen in ein natives Programm (docker exec -i) sonst eine BOM vor die erste Zeile -> curl
# verwirft die erste Config-Zeile (real getroffen: der x-api-key-Header fehlte). Beide Encodings BOM-frei setzen.
$OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container

$GwJs     = '/usr/local/lib/lifeagents-llm-gateway/server.js'
$MockDir  = '/opt/gwtest'
$MockLog  = '/tmp/gwtest_mock.jsonl'
$Units    = @{ mock = 'n8ntest-gwt-mock'; gw = 'n8ntest-gwt'; dead = 'n8ntest-gwt-dead'; real = 'n8ntest-gwt-real'; ka = 'n8ntest-gwt-ka' }
$Canary   = 'CANARY_7f3a9c_PROMPT'
$FakeKey  = 'sk-ant-test-CANARYKEY-0000'

function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs, [string]$StdIn)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('StdIn')) { $out = $StdIn | & $Exe @CmdArgs 2>&1 } else { $out = & $Exe @CmdArgs 2>&1 }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { [string]$_ }) }
}
function Invoke-InC([string[]]$CmdArgs) { Invoke-Native docker (@('exec', $Container) + $CmdArgs) }

$passed = 0; $failed = 0; $skipped = 0
function Pass([string]$m) { $script:passed++; Write-Host "    [PASS] $m" -ForegroundColor Green }
function Fail([string]$m) { $script:failed++; Write-Host "    [FAIL] $m" -ForegroundColor Red }
function Skip([string]$m) { $script:skipped++; Write-Host "    [SKIP] $m" -ForegroundColor Yellow }

# --- Vorbedingungen ------------------------------------------------------------------------------------------
$r = Invoke-InC @('test', '-f', $GwJs)
if ($r.Code -ne 0) { throw "Gateway-Code fehlt im Container ($GwJs) -- Substrat mit Gateway bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset" }
$nodeBin = ((Invoke-InC @('sh', '-c', 'command -v node')).Output -join '').Trim()
if (-not $nodeBin) { throw 'node im Container nicht gefunden.' }

function Stop-TestUnits { foreach ($u in $Units.Values) { Invoke-InC @('systemctl', 'stop', $u) | Out-Null; Invoke-InC @('systemctl', 'reset-failed', $u) | Out-Null } }
function Start-TestUnit([string]$Unit, [string[]]$Env, [string]$Js, [int]$Port) {
    $a = @('systemd-run', "--unit=$Unit", '--collect') + ($Env | ForEach-Object { "--setenv=$_" }) + @($nodeBin, $Js)
    $r = Invoke-InC $a
    if ($r.Code -ne 0) { throw "systemd-run $Unit fehlgeschlagen: $($r.Output -join ' ')" }
    for ($i = 0; $i -lt 25; $i++) {
        $p = Invoke-InC @('sh', '-c', "curl -sf http://127.0.0.1:$Port/__health >/dev/null && echo ok || echo no")
        if ((($p.Output -join '').Trim()) -eq 'ok') { return }
        Start-Sleep -Milliseconds 300
    }
    throw "$Unit wurde nicht bereit (journalctl -u $Unit)."
}

# Sendet einen Body (String, roh) an einen Gateway-Port; liefert @{ Status; Body }.
$script:reqN = 0
function Send-Gw([int]$Port, [string]$Path, [string]$RawBody, [string]$ApiKey = $FakeKey) {
    $script:reqN++
    $hostFile = Join-Path $env:TEMP "gwtest_req_$($script:reqN).json"
    [System.IO.File]::WriteAllText($hostFile, $RawBody, $Utf8NoBom)
    $inC = "/tmp/gwtest_req_$($script:reqN).json"
    Invoke-Native docker @('cp', $hostFile, "${Container}:$inC") | Out-Null
    Remove-Item $hostFile -ErrorAction SilentlyContinue
    # Schluessel per curl-Config auf stdin (nie im argv, /proc/<pid>/cmdline ist lesbar).
    $cfg = "header = `"x-api-key: $ApiKey`"`nheader = `"anthropic-version: 2023-06-01`"`nheader = `"content-type: application/json`"`n"
    $r = Invoke-Native docker @('exec', '-i', $Container, 'curl', '-s', '-K', '-', '-o', '/tmp/gwtest_resp', '-w', '%{http_code}',
        '-X', 'POST', "http://127.0.0.1:$Port$Path", '--data-binary', "@$inC") -StdIn $cfg
    $body = ((Invoke-InC @('cat', '/tmp/gwtest_resp')).Output -join "`n")
    Invoke-InC @('rm', '-f', $inC, '/tmp/gwtest_resp') | Out-Null
    return [pscustomobject]@{ Status = (($r.Output -join '').Trim()); Body = $body }
}
function Clear-MockLog { Invoke-InC @('sh', '-c', ": > $MockLog") | Out-Null }
function Get-LastMockEntry {
    $lines = @((Invoke-InC @('cat', $MockLog)).Output | Where-Object { $_ -match '"dialect":"anthropic"' })
    if ($lines.Count -eq 0) { return $null }
    return ($lines[-1] | ConvertFrom-Json)
}
function Get-UnitJournal([string]$Unit) { (Invoke-InC @('journalctl', '-u', $Unit, '-o', 'cat', '--no-pager')).Output }
function Get-LastUsage([string]$Unit) {
    $u = @(Get-UnitJournal $Unit | Where-Object { $_ -match '"ev":"usage"' })
    if ($u.Count -eq 0) { return $null }
    return ($u[-1] | ConvertFrom-Json)
}
function ConvertTo-Body($obj) { $obj | ConvertTo-Json -Depth 12 -Compress }

$tool1 = [ordered]@{ name = 'tool_a'; description = 'A'; input_schema = [ordered]@{ type = 'object'; properties = @{} } }
$tool2 = [ordered]@{ name = 'tool_b'; description = 'B'; input_schema = [ordered]@{ type = 'object'; properties = @{} } }
$msgs  = @(@{ role = 'user'; content = "hallo $Canary" })

# --- Setup ------------------------------------------------------------------------------------------------------
Write-Host ''
Write-Host "LLM-Gateway-Test (gratis) -- Container $Container"
Write-Host ('-' * 64)
Stop-TestUnits
Invoke-InC @('mkdir', '-p', $MockDir) | Out-Null
Invoke-Native docker @('cp', (Join-Path $RepoRoot 'tests\mock_llm\server.js'), "${Container}:$MockDir/server.js") | Out-Null
Invoke-InC @('sh', '-c', "echo '[]' > $MockDir/scenarios.json") | Out-Null
Start-TestUnit $Units.mock @('MOCK_LLM_PORT=8096', "MOCK_LLM_LOG=$MockLog", "MOCK_LLM_SCENARIOS=$MockDir/scenarios.json") "$MockDir/server.js" 8096
Start-TestUnit $Units.gw @('LLM_GATEWAY_PORT=8095', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=0') $GwJs 8095
Start-TestUnit $Units.dead @('LLM_GATEWAY_PORT=8097', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:1', 'LLM_GATEWAY_KEEPALIVE_HOURS=0') $GwJs 8097
# (k) Keep-Alive mit verkuerztem Takt (1,5 s statt 55 Min), sonst identisch.
Start-TestUnit $Units.ka @('LLM_GATEWAY_PORT=8099', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=1', 'LLM_GATEWAY_KEEPALIVE_EVERY_MS=1500') $GwJs 8099

try {
    # (a) Agenten-Anfrage
    Write-Host '  (a) Agenten-Anfrage -> Werkzeug+System 1h, oben 5m'
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1, $tool2); messages = $msgs }))
    $m = Get-LastMockEntry
    if ($res.Status -eq '200' -and $m -and $m.markers.tool -eq '1h' -and $m.markers.system -eq '1h' -and $m.markers.top -eq '5m') { Pass 'drei Haltepunkte gesetzt' }
    else { Fail "Status=$($res.Status) markers=$($m.markers | ConvertTo-Json -Compress)" }
    $u = Get-LastUsage $Units.gw
    if ($u -and $u.cached -eq $true -and $u.cache_read_input_tokens -eq 50 -and $u.ephemeral_1h_input_tokens -eq 80 -and $u.model -eq 'claude-sonnet-5-5') { Pass 'usage gemessen (JSON)' }
    else { Fail "usage-Zeile: $($u | ConvertTo-Json -Compress)" }

    # (b1) eigene Block-Marker
    Write-Host '  (b1) eigene Block-Marker -> keine statischen Haltepunkte'
    Clear-MockLog
    $t1m = [ordered]@{ name = 'tool_a'; description = 'A'; input_schema = @{ type = 'object' }; cache_control = @{ type = 'ephemeral' } }
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($t1m, $tool2); messages = $msgs }))
    $m = Get-LastMockEntry
    if ($m -and $null -eq $m.markers.system -and $m.markers.tool -eq '5m' -and $m.markers.top -eq '5m') { Pass 'eigener Marker respektiert, oben ergaenzt' }
    else { Fail "markers=$($m.markers | ConvertTo-Json -Compress)" }

    # (b2) nur oberer Marker (z. B. n8n >= 2.37 eingebaute Option)
    Write-Host '  (b2) nur oberer Marker -> statische trotzdem, oben unveraendert'
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; cache_control = [ordered]@{ type = 'ephemeral'; ttl = '1h' }; system = 'SYS'; tools = @($tool1); messages = $msgs }))
    $m = Get-LastMockEntry
    if ($m -and $m.markers.tool -eq '1h' -and $m.markers.system -eq '1h' -and $m.markers.top -eq '1h') { Pass 'statische ergaenzt, oberer Marker unveraendert' }
    else { Fail "markers=$($m.markers | ConvertTo-Json -Compress)" }

    # (c) ohne eigene Werkzeuge / nur Server-Werkzeug
    Write-Host '  (c) Einmal-Aufrufe (ohne eigene Werkzeuge) -> nichts eingefuegt'
    $ok = $true
    foreach ($b in @(
            [ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; messages = $msgs },
            [ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; tools = @([ordered]@{ type = 'web_search_20260209'; name = 'web_search'; max_uses = 1 }); messages = $msgs })) {
        Clear-MockLog
        $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body $b)
        $m = Get-LastMockEntry
        if (-not $m -or $m.markers.top -or $m.markers.tool -or $m.markers.system) { $ok = $false }
    }
    $u = Get-LastUsage $Units.gw
    if ($ok -and $u -and $u.cached -eq $false) { Pass 'unveraendert durchgereicht, trotzdem gemessen (cached=false)' } else { Fail 'Einmal-Aufruf wurde veraendert oder nicht gemessen' }

    # (d) Streaming
    Write-Host '  (d) Streaming (SSE) durchgereicht + usage aus message_start/message_delta'
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-opus-5-5'; max_tokens = 10; stream = $true; system = 'SYS'; tools = @($tool1); messages = $msgs }))
    $u = Get-LastUsage $Units.gw
    if ($res.Status -eq '200' -and $res.Body -match 'event: message_stop' -and $u.stream -eq $true -and $u.cache_creation_input_tokens -eq 100 -and $u.output_tokens -eq 1) { Pass 'SSE vollstaendig, usage gemessen' }
    else { Fail "Status=$($res.Status) usage=$($u | ConvertTo-Json -Compress)" }

    # (e) Upstream tot
    Write-Host '  (e) Upstream nicht erreichbar -> 502 + fester Fehlercode'
    $res = Send-Gw 8097 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; messages = $msgs }))
    $j = @(Get-UnitJournal $Units.dead)
    if ($res.Status -eq '502' -and ($j -match '"code":"ECONNREFUSED"')) { Pass '502 + code ECONNREFUSED' } else { Fail "Status=$($res.Status) journal=$($j -join ' | ')" }

    # (g) 400 mit cache_control -> Wiederholung ohne
    Write-Host '  (g) Anthropic lehnt Haltepunkte ab (400) -> einmal ohne Einfuegen wiederholt'
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1); messages = @(@{ role = 'user'; content = '__mock_400_cache_control__' }) }))
    $u = Get-LastUsage $Units.gw
    $m = Get-LastMockEntry
    if ($res.Status -eq '200' -and $u.fallback -eq $true -and $u.cached -eq $false -and -not $m.markers.top) { Pass 'Wiederholung ohne Haltepunkte, fallback=true' }
    else { Fail "Status=$($res.Status) usage=$($u | ConvertTo-Json -Compress)" }

    # (j) ein Werkzeug je Antwort: Agenten-Anfrage -> tool_choice auto + disable_parallel_tool_use; eigener Wert bleibt
    Write-Host '  (j) Agenten-Anfrage -> hoechstens ein Werkzeug je Antwort; eigenes tool_choice unveraendert'
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1, $tool2); messages = $msgs }))
    $m1 = Get-LastMockEntry
    Clear-MockLog
    $res2 = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1); tool_choice = [ordered]@{ type = 'none' }; messages = $msgs }))
    $m2 = Get-LastMockEntry
    Clear-MockLog
    $res3 = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; messages = $msgs }))
    $m3 = Get-LastMockEntry
    if ($res.Status -eq '200' -and $m1.tool_choice.type -eq 'auto' -and $m1.tool_choice.disable_parallel_tool_use -eq $true -and
        $res2.Status -eq '200' -and $m2.tool_choice.type -eq 'none' -and $null -eq $m2.tool_choice.disable_parallel_tool_use -and
        $res3.Status -eq '200' -and $null -eq $m3.tool_choice) { Pass 'auto+disable_parallel_tool_use gesetzt; none unveraendert; Einmal-Aufruf ohne tool_choice' }
    else { Fail "tool_choice: agent=$($m1.tool_choice | ConvertTo-Json -Compress) none=$($m2.tool_choice | ConvertTo-Json -Compress) einmal=$($m3.tool_choice | ConvertTo-Json -Compress)" }

    # (k) Keep-Alive: Agenten-Anfang wird mit max_tokens 0 angestupst (gleiche Haltepunkte, ohne oberen Marker und ohne
    #     Gespraech); Einmal-Aufrufe werden nicht gemerkt; KEEPALIVE_HOURS=0 schaltet es ab.
    Write-Host '  (k) Keep-Alive: Agenten-Anfang angestupst (max_tokens 0), Einmal-Aufruf nicht, 0 = aus'
    $null = Send-Gw 8099 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1, $tool2); messages = $msgs }))
    $null = Send-Gw 8099 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; messages = $msgs }))
    Clear-MockLog
    Start-Sleep -Seconds 4
    $kaReq = @((Invoke-InC @('cat', $MockLog)).Output | Where-Object { $_ -match '"dialect":"anthropic"' } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.max_tokens -eq 0 })
    $hKa = ((Invoke-InC @('curl', '-s', 'http://127.0.0.1:8099/__health')).Output -join '') | ConvertFrom-Json
    $hOff = ((Invoke-InC @('curl', '-s', 'http://127.0.0.1:8095/__health')).Output -join '') | ConvertFrom-Json
    $kaUse = @(Get-UnitJournal $Units.ka | Where-Object { $_ -match '"keepalive":true' } | ForEach-Object { $_ | ConvertFrom-Json })
    $k0 = if ($kaReq.Count -gt 0) { $kaReq[0] } else { $null }
    if ($k0 -and $k0.markers.tool -eq '1h' -and $k0.markers.system -eq '1h' -and -not $k0.markers.top -and $k0.tool_choice.disable_parallel_tool_use -eq $true -and
        $hKa.keepalive.on -eq $true -and $hKa.keepalive.entries -eq 1 -and $hOff.keepalive.on -eq $false -and
        $kaUse.Count -ge 1 -and $kaUse[0].status -eq 200) {
        Pass "angestupst ($($kaReq.Count)x in 4 s), Haltepunkte gleich, oben keiner, 1 Eintrag, usage keepalive:true; Port 8095 (0 h) aus"
    }
    else { Fail "keepalive-Anfragen=$($kaReq.Count) erste=$($k0 | ConvertTo-Json -Compress -Depth 5) health=$($hKa | ConvertTo-Json -Compress -Depth 4) aus=$($hOff.keepalive | ConvertTo-Json -Compress) usage=$($kaUse.Count)" }

    # (f) Privacy: Kanarien + Schluessel nie im Journal (inkl. kaputtem JSON)
    Write-Host '  (f) Privacy: Prompt-Inhalt und Schluessel nie im Journal'
    $res = Send-Gw 8095 '/v1/messages' ('{"model":"x","messages":[{"role":"user","content":"' + $Canary + '"}')   # kaputtes JSON
    $all = @(Get-UnitJournal $Units.gw) + @(Get-UnitJournal $Units.dead) + @(Get-UnitJournal $Units.ka)
    $leak = @($all | Where-Object { $_ -match 'CANARY' })
    if ($leak.Count -eq 0 -and (@($all) -match '"code":"parse_error"')) { Pass 'kein Inhalt/Schluessel im Journal, kaputtes JSON nur als parse_error' }
    else { Fail "Journal enthaelt Inhalt/Schluessel: $($leak -join ' | ')" }

    # (i) ungueltiges Anfrage-Ziel ('//host/…') -> 400, Prozess lebt weiter (kein uncaughtException-Neustart)
    Write-Host '  (i) ungueltiges Anfrage-Ziel -> 400, Dienst laeuft weiter'
    $pidBefore = ((Invoke-InC @('systemctl', 'show', $Units.gw, '-p', 'MainPID', '--value')).Output -join '').Trim()
    $r = Invoke-InC @('curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--request-target', '//evil.example/v1/messages', '-X', 'POST', 'http://127.0.0.1:8095/')
    $pidAfter = ((Invoke-InC @('systemctl', 'show', $Units.gw, '-p', 'MainPID', '--value')).Output -join '').Trim()
    if ((($r.Output -join '').Trim()) -eq '400' -and $pidBefore -eq $pidAfter -and $pidAfter -ne '0') { Pass '400 + gleicher Prozess' }
    else { Fail "Status=$($r.Output -join '') PID $pidBefore -> $pidAfter" }

    # (h) echter Upstream, gratis (count_tokens)
    Write-Host '  (h) echter Upstream: /v1/messages/count_tokens (kostenlos)'
    $envFile = Join-Path $RepoRoot '.env'
    $realKey = $null
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match '^\s*TEST_ANTHROPIC_API_KEY=' } | Select-Object -First 1
        if ($line) { $realKey = ($line -split '=', 2)[1].Trim() }
    }
    if (-not $realKey) { Skip 'TEST_ANTHROPIC_API_KEY fehlt in .env' }
    else {
        Start-TestUnit $Units.real @('LLM_GATEWAY_PORT=8098') $GwJs 8098
        $res = Send-Gw 8098 '/v1/messages/count_tokens' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; messages = @(@{ role = 'user'; content = 'Hallo' }) })) $realKey
        $jr = @(Get-UnitJournal $Units.real)
        $keyLeak = @($jr | Where-Object { $_.Contains($realKey) })
        if ($res.Status -eq '200' -and $res.Body -match '"input_tokens"\s*:\s*[1-9]' -and $keyLeak.Count -eq 0) { Pass 'TLS/Host/Auth/Kompression ok (count_tokens 200)' }
        else { Fail "Status=$($res.Status) body=$($res.Body.Substring(0, [Math]::Min(200, $res.Body.Length)))" }
    }

    # Produktiver Gateway gesund?
    $h = Get-LlmGatewayHealth -Container $Container
    if ($h -and $h.ok) { Pass "produktiver Gateway gesund (upstream $($h.upstream), static_ttl $($h.static_ttl))" } else { Fail 'produktiver Gateway /__health nicht ok' }
} finally {
    if ($Verbose) { Write-Host ((Get-UnitJournal $Units.gw) -join "`n") -ForegroundColor DarkGray }
    Stop-TestUnits
}

Write-Host ''
Write-Host ('-' * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed bestanden, $failed fehlgeschlagen, $skipped uebersprungen." -ForegroundColor $color
exit $failed
