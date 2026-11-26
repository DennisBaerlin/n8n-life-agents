#Requires -Version 5.1
# llm_gateway_test.ps1 -- Gratis-Tier fuer den lokalen LLM-Gateway (provisioning/llm_gateway/server.js).
#
# Prueft die Gateway-Logik deterministisch im laufenden Substrat (bootstrap_test_n8n.ps1), ohne den
# produktiven Gateway anzufassen: eigene transiente systemd-Units (Muster enable_mock_llm.ps1):
#   n8ntest-gwt-mock  = tests/mock_llm/server.js auf 127.0.0.1:8096 (Upstream-Stub, zeichnet `markers` auf)
#   n8ntest-gwt       = der installierte Gateway-Code auf 127.0.0.1:8095, Upstream = der Stub
#   n8ntest-gwt-dead  = Gateway auf 127.0.0.1:8097, Upstream = toter Port (Ausfallverhalten)
#   n8ntest-gwt-real  = Gateway auf 127.0.0.1:8098, Upstream = api.anthropic.com (nur Fall h, count_tokens = gratis)
#
# Faelle: (a) Agenten-Anfrage -> 3 Haltepunkte (Werkzeug+System 1h, oben 5m) · (b1) eigene Block-Marker -> keine
# statischen · (b2) nur oberer Marker -> statische trotzdem, oben unveraendert · (c) ohne eigene Werkzeuge (auch nur
# web_search) -> nichts eingefuegt · (d) Streaming durchgereicht + usage gemessen · (e) Upstream tot -> 502 + fester
# Fehlercode · (f) Kanarien-Text + Test-Schluessel nie im Journal (auch bei kaputtem JSON) · (g) 400 mit cache_control
# -> einmal ohne Einfuegen wiederholt (fallback) · (i) ungueltiges Anfrage-Ziel -> 400 ohne Absturz · (j) Agenten-Anfrage ->
# tool_choice auto + disable_parallel_tool_use, eigener Wert unveraendert; (j2) Schalter LLM_GATEWAY_SERIAL_TOOLS=0 = nichts
# eingefuegt · (k) Keep-Alive (eigene Unit, Takt 1,5 s):
# Agenten-Anfang mit max_tokens 0 angestupst, Einmal-Aufruf nicht gemerkt, KEEPALIVE_HOURS=0 = aus · (l) Workflow-Kennung
# (Kosten-Report): Kennzeile `<<la-wf:NAME>>` (String-/Block-System, Kette nur mit Kennzeile, 400-Wiederholung) und Header
# x-lifeagents-workflow erreichen upstream nie, wf steht in der usage-Zeile + usage.jsonl, GET /__usage blaettert,
# Keep-Alive-Schluessel mit/ohne Kennzeile gleich · (h) echter Upstream: POST /v1/messages/count_tokens (kostenlos)
# mit TEST_ANTHROPIC_API_KEY (fehlt er -> SKIP). (m) Telegram-Relay (eigene Units: Mock-Telegram 8103, Gateway 8102):
# Reaktion durchgereicht (❤ ohne VS16, dazu 👀 🙏 😁), Methoden-Allowlist (404, kein Anthropic-Forward), Pfad mit Query -> 404, kaputtes Token -> 400,
# Sticker erst Upload (multipart, Dateiname) dann file_id, Sticker-Name ausserhalb des Musters -> 400, Token nie im Journal.
# (o) still tote Keep-Alive-Verbindung (Attrappe schweigt auf der Verbindung): nach dem Leerlauf-Limit frische Verbindung statt
# Haenger; lange Antwort auf wiederverwendeter Verbindung nicht abgebrochen; LLM_GATEWAY_UPSTREAM_IDLE_MS=0 (Unit 8104) = nie wiederverwenden.
#
# N8NTEST_RUNTIME=compose (Docker-Verbund, bootstrap_test_stack.ps1): statt der systemd-Einheiten starten eigene Container im
# Netz-Namensraum des anchor (127.0.0.1 wie der echte Gateway): die Gateways aus dem Abbild und mit dem Code (/gw/server.js) des echten
# Gateway-Containers, Stub-LLM und Telegram-Stub im master-Abbild; das Journal ist `docker logs`. Der echte Gateway-Container <p>-gateway
# bleibt unberuehrt und wird am Ende neu gestartet und auf Gesundheit und Privacy-Log geprueft (Fall n).
#
# Kein LLM-Credit (count_tokens ist laut Anthropic kostenlos). Exit = Anzahl FAIL.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# PS 5.1 stellt beim Pipen in ein natives Programm (docker exec -i) sonst eine BOM vor die erste Zeile -> curl
# verwirft die erste Config-Zeile (Symptom: der x-api-key-Header fehlt). Beide Encodings BOM-frei setzen.
$OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\test_n8n_state.ps1"
. "$PSScriptRoot\..\lib\dotenv.ps1"
. "$PSScriptRoot\..\lib\test_stack.ps1"
$suiteRuntime = Get-TestSuiteRuntime
$conn = Get-TestN8nConnection
$Container = $conn.Container
$IsCompose = ($suiteRuntime -eq 'compose')
if ($IsCompose) {
    $target = Get-TestN8nTarget -Container $Container
    Assert-TestSuiteStateRuntime -State (Get-TestN8nState)
}

# Pfade je Unterbau: klassisch der installierte Gateway im Substrat, im Verbund /gw (Volume gw_code, im master und im Gateway gleich).
$GwJs      = if ($IsCompose) { '/gw/server.js' } else { '/usr/local/lib/lifeagents-llm-gateway/server.js' }
$StickerDir = if ($IsCompose) { '/gw/stickers' } else { '/usr/local/lib/lifeagents-llm-gateway/stickers' }
$MockDir   = if ($IsCompose) { '/tmp' } else { '/opt/gwtest' }
$TgDir     = if ($IsCompose) { '/tmp' } else { '/opt/gwtest_tg' }
$MockLog  = '/tmp/gwtest_mock.jsonl'
$UsageDir = '/tmp/gwtest_usage'
$Units    = @{ mock = 'n8ntest-gwt-mock'; gw = 'n8ntest-gwt'; dead = 'n8ntest-gwt-dead'; real = 'n8ntest-gwt-real'; ka = 'n8ntest-gwt-ka'; tgmock = 'n8ntest-gwt-tgmock'; tg = 'n8ntest-gwt-tg'; par = 'n8ntest-gwt-par'; fresh = 'n8ntest-gwt-fresh' }
$Canary   = 'CANARY_7f3a9c_PROMPT'
$FakeKey  = 'sk-ant-test-CANARYKEY-0000'

. "$PSScriptRoot\..\lib\test_common.ps1"
function Invoke-InC([string[]]$CmdArgs) { Invoke-Native docker (@('exec', $Container) + $CmdArgs) }
# Invoke-InU <einheit> <befehl> -- im Container, der die Einheit traegt: klassisch das Substrat, im Verbund ihr eigener Container
# (dort liegen Stub-Log, Zaehler und Telegram-Log; das Gateway-Abbild ist Alpine, `cat`/`wc` genuegen).
function Invoke-InU([string]$Unit, [string[]]$CmdArgs) {
    if (-not $IsCompose) { return (Invoke-InC $CmdArgs) }
    return (Invoke-Native docker (@('exec', (Get-TestStackUnitName -Project $target.Project -Unit $Unit)) + $CmdArgs))
}

$passed = 0; $failed = 0; $skipped = 0
function Pass([string]$m) { $script:passed++; Write-Host "    [PASS] $m" -ForegroundColor Green }
function Fail([string]$m) { $script:failed++; Write-Host "    [FAIL] $m" -ForegroundColor Red }
function Skip([string]$m) { $script:skipped++; Write-Host "    [SKIP] $m" -ForegroundColor Yellow }

# --- Vorbedingungen ------------------------------------------------------------------------------------------
$r = Invoke-InC @('test', '-f', $GwJs)
if ($r.Code -ne 0) {
    $hint = if ($IsCompose) { 'Verbund bauen: .\scripts\dev\bootstrap_test_stack.ps1 -Reset' } else { 'Substrat mit Gateway bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset' }
    throw "Gateway-Code fehlt im Container ($GwJs) -- $hint"
}
if ($IsCompose) {
    # Abbilder: Gateway-Einheiten aus dem Abbild des echten Gateways, Attrappen aus dem des master (Node darin).
    $GwImage = ((Invoke-Native docker @('inspect', '-f', '{{.Config.Image}}', $target.Gateway)).Output -join '').Trim()
    $MasterImage = ((Invoke-Native docker @('inspect', '-f', '{{.Config.Image}}', $target.Master)).Output -join '').Trim()
    if (-not $GwImage -or -not $MasterImage) { throw "Abbilder von $($target.Gateway) / $($target.Master) nicht lesbar (laeuft der Verbund?)." }
} else {
    $nodeBin = ((Invoke-InC @('sh', '-c', 'command -v node')).Output -join '').Trim()
    if (-not $nodeBin) { throw 'node im Container nicht gefunden.' }
}

function Stop-TestUnits {
    foreach ($u in $Units.Values) {
        if ($IsCompose) { [void](Invoke-Native docker @('rm', '-fv', (Get-TestStackUnitName -Project $target.Project -Unit $u))) }
        else { Invoke-InC @('systemctl', 'stop', $u) | Out-Null; Invoke-InC @('systemctl', 'reset-failed', $u) | Out-Null }
    }
}
# Start-TestUnit <einheit> <env> <js> <port> [-Files @{ rechner-pfad = ziel-pfad }] -- klassisch systemd-run im Substrat (Dateien vorher
# hineinkopiert), im Verbund ein Container: -Js = der Gateway-Code -> Gateway-Einheit, sonst eine Attrappe (create, cp, start).
function Start-TestUnit([string]$Unit, [string[]]$Env, [string]$Js, [int]$Port, [hashtable]$Files = @{}) {
    if ($IsCompose) {
        $name = Get-TestStackUnitName -Project $target.Project -Unit $Unit
        [void](Invoke-Native docker @('rm', '-fv', $name))
        if ($Js -eq $GwJs) {
            $r = Invoke-Native docker (Get-TestStackGatewayUnitArgs -Project $target.Project -Unit $Unit -Image $GwImage -Env $Env -RepoRoot $RepoRoot)
        } else {
            $r = Invoke-Native docker (Get-TestStackNodeUnitCreateArgs -Project $target.Project -Unit $Unit -Image $MasterImage -Env $Env -ScriptPath $Js -RepoRoot $RepoRoot)
            foreach ($f in $Files.Keys) {
                if ($r.Code -ne 0) { break }
                $r = Invoke-Native docker @('cp', $f, "${name}:$($Files[$f])")
            }
            if ($r.Code -eq 0) { $r = Invoke-Native docker @('start', $name) }
        }
        if ($r.Code -ne 0) { throw "Container $name fehlgeschlagen: $($r.Output -join ' ')" }
    } else {
        foreach ($f in $Files.Keys) {
            Invoke-InC @('mkdir', '-p', (Split-Path $Files[$f] -Parent).Replace('\', '/')) | Out-Null
            Invoke-Native docker @('cp', $f, "${Container}:$($Files[$f])") | Out-Null
        }
        $a = @('systemd-run', "--unit=$Unit", '--collect') + ($Env | ForEach-Object { "--setenv=$_" }) + @($nodeBin, $Js)
        $r = Invoke-InC $a
        if ($r.Code -ne 0) { throw "systemd-run $Unit fehlgeschlagen: $($r.Output -join ' ')" }
    }
    for ($i = 0; $i -lt 25; $i++) {
        $p = Invoke-InC @('sh', '-c', "curl -sf http://127.0.0.1:$Port/__health >/dev/null && echo ok || echo no")
        if ((($p.Output -join '').Trim()) -eq 'ok') { return }
        Start-Sleep -Milliseconds 300
    }
    $where = if ($IsCompose) { 'docker logs ' + (Get-TestStackUnitName -Project $target.Project -Unit $Unit) } else { 'journalctl -u ' + $Unit }
    throw "$Unit wurde nicht bereit ($where)."
}
# Get-UnitIdentity -- aendert sich, wenn der Prozess neu gestartet wurde oder endete: klassisch MainPID, im Verbund Zustand + Start-Zeit.
function Get-UnitIdentity([string]$Unit) {
    if ($IsCompose) { return ((Invoke-Native docker @('inspect', '-f', '{{.State.Running}} {{.State.StartedAt}}', (Get-TestStackUnitName -Project $target.Project -Unit $Unit))).Output -join '').Trim() }
    return ((Invoke-InC @('systemctl', 'show', $Unit, '-p', 'MainPID', '--value')).Output -join '').Trim()
}
# Sendet einen Body (String, roh) an einen Gateway-Port; liefert @{ Status; Body }.
$script:reqN = 0
function Send-Gw([int]$Port, [string]$Path, [string]$RawBody, [string]$ApiKey = $FakeKey, [string]$Workflow = '', [int]$MaxTime = 60) {
    $script:reqN++
    $hostFile = Join-Path $env:TEMP "gwtest_req_$($script:reqN).json"
    [System.IO.File]::WriteAllText($hostFile, $RawBody, $Utf8NoBom)
    $inC = "/tmp/gwtest_req_$($script:reqN).json"
    Invoke-Native docker @('cp', $hostFile, "${Container}:$inC") | Out-Null
    Remove-Item $hostFile -ErrorAction SilentlyContinue
    # Schluessel per curl-Config auf stdin (nie im argv, /proc/<pid>/cmdline ist lesbar).
    $cfg = "header = `"x-api-key: $ApiKey`"`nheader = `"anthropic-version: 2023-06-01`"`nheader = `"content-type: application/json`"`n"
    if ($Workflow) { $cfg += "header = `"x-lifeagents-workflow: $Workflow`"`n" }
    # Seconds = Dauer laut curl (time_total), ohne den docker-exec-Aufwand.
    $r = Invoke-Native docker @('exec', '-i', $Container, 'curl', '-s', '-K', '-', '-m', [string]$MaxTime, '-o', '/tmp/gwtest_resp', '-w', '%{http_code} %{time_total}',
        '-X', 'POST', "http://127.0.0.1:$Port$Path", '--data-binary', "@$inC") -StdIn $cfg
    $body = ((Invoke-InC @('cat', '/tmp/gwtest_resp')).Output -join "`n")
    Invoke-InC @('rm', '-f', $inC, '/tmp/gwtest_resp') | Out-Null
    $w = (($r.Output -join '').Trim()) -split ' '
    $secs = 0.0
    [void][double]::TryParse($w[-1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$secs)
    return [pscustomobject]@{ Status = $w[0]; Body = $body; Seconds = $secs }
}
function Clear-MockLog { Invoke-InU $Units.mock @('sh', '-c', ": > $MockLog") | Out-Null }
# Letzte echte Anfrage am Stub: Keep-Alive-Anstupser (max_tokens 0) der Unit aus Fall (k) laufen im Hintergrund weiter
# und landen im selben Log -> auslassen, sonst liest ein spaeterer Fall den Anstupser statt seiner Anfrage.
function Get-MockEntries {
    @((Invoke-InU $Units.mock @('cat', $MockLog)).Output | Where-Object { $_ -match '"dialect":"anthropic"' } |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.max_tokens -ne 0 })
}
function Get-LastMockEntry {
    $e = @(Get-MockEntries)
    if ($e.Count -eq 0) { return $null }
    return $e[-1]
}
function Get-UnitJournal([string]$Unit) {
    if ($IsCompose) { return (Invoke-Native docker @('logs', (Get-TestStackUnitName -Project $target.Project -Unit $Unit))).Output }
    (Invoke-InC @('journalctl', '-u', $Unit, '-o', 'cat', '--no-pager')).Output
}
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
$emptyScenarios = Join-Path $env:TEMP 'gwtest_scenarios.json'
[System.IO.File]::WriteAllText($emptyScenarios, '[]', $Utf8NoBom)
Start-TestUnit $Units.mock @('MOCK_LLM_PORT=8096', "MOCK_LLM_LOG=$MockLog", "MOCK_LLM_SCENARIOS=$MockDir/scenarios.json") "$MockDir/server.js" 8096 `
    -Files @{ (Join-Path $RepoRoot 'tests\mock_llm\server.js') = "$MockDir/server.js"; $emptyScenarios = "$MockDir/scenarios.json" }
Remove-Item $emptyScenarios -ErrorAction SilentlyContinue
# Zaehler-Ordner: klassisch im Substrat, im Verbund ein tmpfs je Gateway-Einheit (Get-TestStackGatewayUnitArgs).
if (-not $IsCompose) { Invoke-InC @('sh', '-c', "rm -rf $UsageDir && mkdir -p $UsageDir") | Out-Null }
Start-TestUnit $Units.gw @('LLM_GATEWAY_PORT=8095', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=0', "LLM_GATEWAY_USAGE_DIR=$UsageDir") $GwJs 8095
Start-TestUnit $Units.dead @('LLM_GATEWAY_PORT=8097', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:1', 'LLM_GATEWAY_KEEPALIVE_HOURS=0') $GwJs 8097
# (j2) Schalter LLM_GATEWAY_SERIAL_TOOLS=0 (Probelauf parallele Werkzeug-Aufrufe), sonst identisch.
Start-TestUnit $Units.par @('LLM_GATEWAY_PORT=8094', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=0', 'LLM_GATEWAY_SERIAL_TOOLS=0', "LLM_GATEWAY_USAGE_DIR=$UsageDir") $GwJs 8094
# (o) Schalter LLM_GATEWAY_UPSTREAM_IDLE_MS=0 (Upstream-Verbindung nie wiederverwenden), sonst identisch.
Start-TestUnit $Units.fresh @('LLM_GATEWAY_PORT=8104', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=0', 'LLM_GATEWAY_UPSTREAM_IDLE_MS=0') $GwJs 8104
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

    # (j2) Schalter aus: Agenten-Anfrage ohne tool_choice bleibt ohne (parallele Aufrufe erlaubt), Caching laeuft weiter;
    #      ein eigenes tool_choice bleibt auch hier unveraendert.
    Write-Host '  (j2) LLM_GATEWAY_SERIAL_TOOLS=0 -> kein tool_choice eingefuegt, Haltepunkte weiter gesetzt'
    Clear-MockLog
    $res = Send-Gw 8094 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1, $tool2); messages = $msgs }))
    $p1 = Get-LastMockEntry
    Clear-MockLog
    $res2 = Send-Gw 8094 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1); tool_choice = [ordered]@{ type = 'none' }; messages = $msgs }))
    $p2 = Get-LastMockEntry
    if ($res.Status -eq '200' -and $p1 -and $null -eq $p1.tool_choice -and $p1.markers.tool -eq '1h' -and $p1.markers.top -eq '5m' -and
        $res2.Status -eq '200' -and $p2.tool_choice.type -eq 'none') { Pass 'Schalter 0: kein disable_parallel_tool_use, Caching unveraendert, eigener Wert bleibt' }
    else { Fail "Schalter 0: agent=$($p1.tool_choice | ConvertTo-Json -Compress) markers=$($p1.markers | ConvertTo-Json -Compress) none=$($p2.tool_choice | ConvertTo-Json -Compress)" }

    # (k) Keep-Alive: Agenten-Anfang wird mit max_tokens 0 angestupst (gleiche Haltepunkte, ohne oberen Marker und ohne
    #     Gespraech); Einmal-Aufrufe werden nicht gemerkt; KEEPALIVE_HOURS=0 schaltet es ab.
    Write-Host '  (k) Keep-Alive: Agenten-Anfang angestupst (max_tokens 0), Einmal-Aufruf nicht, 0 = aus'
    $null = Send-Gw 8099 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; tools = @($tool1, $tool2); messages = $msgs }))
    $null = Send-Gw 8099 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; messages = $msgs }))
    Clear-MockLog
    Start-Sleep -Seconds 4
    $kaReq = @((Invoke-InU $Units.mock @('cat', $MockLog)).Output | Where-Object { $_ -match '"dialect":"anthropic"' } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.max_tokens -eq 0 })
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

    # (l) Workflow-Kennung (Kosten-Report): Kennzeile + Header erreichen upstream nie, wf wird gemessen
    Write-Host '  (l) Workflow-Kennung: Kennzeile/Header nie upstream, wf in usage + usage.jsonl, /__usage, Keep-Alive-Schluessel stabil'
    $lOk = $true; $lWhy = @()
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = "<<la-wf:agent.demo_agent>>`nSYS persona: butler"; tools = @($tool1); messages = $msgs }))
    $m = Get-LastMockEntry; $u = Get-LastUsage $Units.gw
    if (-not ($res.Status -eq '200' -and $m.wf_tag_seen -eq $false -and $m.system_tail -eq 'SYS persona: butler' -and $m.markers.system -eq '1h' -and $u.wf -eq 'agent.demo_agent')) { $lOk = $false; $lWhy += "string mock=$($m | ConvertTo-Json -Compress -Depth 4) wf=$($u.wf)" }
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = @([ordered]@{ type = 'text'; text = "<<la-wf:agent.guide>>`nBLOCK" }); tools = @($tool1); messages = $msgs }))
    $m = Get-LastMockEntry; $u = Get-LastUsage $Units.gw
    if (-not ($m.wf_tag_seen -eq $false -and $m.system_tail -eq 'BLOCK' -and $u.wf -eq 'agent.guide')) { $lOk = $false; $lWhy += "block mock=$($m | ConvertTo-Json -Compress -Depth 4)" }
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = "<<la-wf:agent.advisor.cron_review>>`n"; messages = $msgs }))
    $m = Get-LastMockEntry; $u = Get-LastUsage $Units.gw
    if (-not ($m.wf_tag_seen -eq $false -and $m.has_system -eq $false -and $u.wf -eq 'agent.advisor.cron_review')) { $lOk = $false; $lWhy += "kette mock=$($m | ConvertTo-Json -Compress -Depth 4)" }
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = 'SYS'; messages = $msgs })) -Workflow 'agent.tool_web_search'
    $m = Get-LastMockEntry; $u = Get-LastUsage $Units.gw
    if (-not ($m.wf_header_seen -eq $false -and $u.wf -eq 'agent.tool_web_search')) { $lOk = $false; $lWhy += "header mock=$($m | ConvertTo-Json -Compress -Depth 4) wf=$($u.wf)" }
    Clear-MockLog
    $res = Send-Gw 8095 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = "<<la-wf:agent.demo_agent>>`nSYS"; tools = @($tool1); messages = @(@{ role = 'user'; content = '__mock_400_cache_control__' }) }))
    $all = @(Get-MockEntries)
    $u = Get-LastUsage $Units.gw
    if (-not ($res.Status -eq '200' -and $all.Count -eq 2 -and @($all | Where-Object { $_.wf_tag_seen }).Count -eq 0 -and $u.fallback -eq $true -and $u.wf -eq 'agent.demo_agent')) { $lOk = $false; $lWhy += "400 n=$($all.Count) fallback=$($u.fallback)" }
    # usage.jsonl + /__usage (Seite 1 von 2, dann der Rest)
    $p1 = ((Invoke-InC @('curl', '-s', 'http://127.0.0.1:8095/__usage?limit=2')).Output -join '') | ConvertFrom-Json
    $p2 = ((Invoke-InC @('curl', '-s', "http://127.0.0.1:8095/__usage?limit=5000&after=$($p1.next_after)")).Output -join '') | ConvertFrom-Json
    $fileN = [int](((Invoke-InU $Units.gw @('sh', '-c', "wc -l < $UsageDir/usage.jsonl")).Output -join '').Trim())
    if (-not ($p1.rows.Count -eq 2 -and $p1.has_more -eq $true -and ($p1.rows.Count + $p2.rows.Count) -eq $fileN -and $p2.has_more -eq $false -and
              @($p2.rows | Where-Object { $_.wf -eq 'agent.tool_web_search' }).Count -eq 1 -and $p1.rows[0].id -match '^[0-9]{13}-[0-9a-f]{6}-[0-9]{6}$')) {
        $lOk = $false; $lWhy += "usage p1=$($p1.rows.Count)/$($p1.has_more) p2=$($p2.rows.Count) datei=$fileN" }
    # Keep-Alive-Schluessel: derselbe Anfang wie (k), jetzt mit Kennzeile -> weiterhin genau 1 Eintrag
    $null = Send-Gw 8099 '/v1/messages' (ConvertTo-Body ([ordered]@{ model = 'claude-sonnet-5-5'; max_tokens = 10; system = "<<la-wf:agent.monitor>>`nSYS"; tools = @($tool1, $tool2); messages = $msgs }))
    $hKa2 = ((Invoke-InC @('curl', '-s', 'http://127.0.0.1:8099/__health')).Output -join '') | ConvertFrom-Json
    if ($hKa2.keepalive.entries -ne 1) { $lOk = $false; $lWhy += "keepalive entries=$($hKa2.keepalive.entries) (erwartet 1)" }
    if ($lOk) { Pass 'Kennzeile (String/Block/Kette/400) + Header nie upstream; wf gemessen; /__usage blaettert; 1 Keep-Alive-Eintrag' }
    else { Fail ($lWhy -join ' | ') }

    # (o) still tote Keep-Alive-Verbindung: die Attrappe beantwortet auf einer Verbindung nur die erste Anfrage mit Marker,
    #     danach kommt dort nie ein Byte (kein FIN, kein RST). Nach mehr als dem Leerlauf-Limit (Standard 4 s) darf der
    #     Gateway sie nicht mehr nehmen: frische Verbindung, Antwort in Sekunden statt Haenger. Eine legitim lange Antwort
    #     auf einer wiederverwendeten Verbindung (laenger als das Limit) wird nicht abgebrochen. Schalter 0 = nie wiederverwenden.
    Write-Host '  (o) still tote Keep-Alive-Verbindung -> frische Verbindung; lange Antwort bleibt; Schalter 0'
    $bh = ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; max_tokens = 10; system = 'SYS'; messages = @(@{ role = 'user'; content = '__mock_blackhole_reuse__' }) })
    Clear-MockLog
    $r1 = Send-Gw 8095 '/v1/messages' $bh
    Start-Sleep -Milliseconds 5500
    $r2 = Send-Gw 8095 '/v1/messages' $bh -MaxTime 20
    $e = @(Get-MockEntries)
    $answered = @($e | Where-Object { $_.decision -ne 'blackhole' })
    if ($r1.Status -eq '200' -and $r2.Status -eq '200' -and $r2.Seconds -lt 3 -and $answered.Count -eq 2 -and $answered[0].conn -ne $answered[1].conn -and
        @($e | Where-Object { $_.decision -eq 'blackhole' }).Count -eq 0) {
        Pass "nach Leerlauf frische Verbindung, Antwort in $($r2.Seconds) s (kein Haenger)"
    }
    else { Fail "Status=$($r1.Status)/$($r2.Status) Dauer=$($r2.Seconds)s stub=$($e | Select-Object conn, decision | ConvertTo-Json -Compress)" }

    $quick = ConvertTo-Body ([ordered]@{ model = 'claude-opus-5-5'; max_tokens = 10; system = 'SYS'; messages = @(@{ role = 'user'; content = 'kurz' }) })
    $slow = ConvertTo-Body ([ordered]@{ model = 'claude-opus-5-5'; max_tokens = 10; system = 'SYS'; messages = @(@{ role = 'user'; content = '__mock_delay_ms_6500__' }) })
    Clear-MockLog
    $errBefore = @(Get-UnitJournal $Units.gw | Where-Object { $_ -match '"ev":"error"' }).Count
    $null = Send-Gw 8095 '/v1/messages' $quick
    $r3 = Send-Gw 8095 '/v1/messages' $slow -MaxTime 30
    $e = @(Get-MockEntries)
    $errs = @(Get-UnitJournal $Units.gw | Where-Object { $_ -match '"ev":"error"' } | Select-Object -Skip $errBefore)
    if ($r3.Status -eq '200' -and $r3.Seconds -ge 6 -and $e.Count -eq 2 -and $e[0].conn -eq $e[1].conn -and $errs.Count -eq 0) {
        Pass "lange Antwort ($($r3.Seconds) s) auf wiederverwendeter Verbindung nicht abgebrochen, kein Fehler-Ereignis"
    }
    else { Fail "lange Antwort: Status=$($r3.Status) Dauer=$($r3.Seconds)s conns=$(@($e | ForEach-Object { $_.conn }) -join ',') fehler=$($errs -join ' | ')" }

    # Aufrufer bricht ab (n8n): auf wiederverwendeter Verbindung meldet das Abbrechen ECONNRESET; das darf keine zweite
    # (bezahlte) Anfrage ausloesen, die niemand liest.
    $slow4 = ConvertTo-Body ([ordered]@{ model = 'claude-opus-5-5'; max_tokens = 10; system = 'SYS'; messages = @(@{ role = 'user'; content = '__mock_delay_ms_4000__' }) })
    Clear-MockLog
    $errBefore = @(Get-UnitJournal $Units.gw | Where-Object { $_ -match '"ev":"error"' }).Count
    $null = Send-Gw 8095 '/v1/messages' $quick
    $r4 = Send-Gw 8095 '/v1/messages' $slow4 -MaxTime 1
    Start-Sleep -Seconds 4
    $e = @(Get-MockEntries)
    $errs = @(Get-UnitJournal $Units.gw | Where-Object { $_ -match '"ev":"error"' } | Select-Object -Skip $errBefore)
    if ($r4.Status -eq '000' -and $e.Count -eq 2 -and $e[0].conn -eq $e[1].conn -and @($errs -match 'stale_socket_retry').Count -eq 0 -and @($errs -match '"code":"client_closed"').Count -eq 1) {
        Pass 'Abbruch des Aufrufers: keine zweite Anfrage upstream, nur client_closed'
    }
    else { Fail "Abbruch: Status=$($r4.Status) stub=$($e.Count) conns=$(@($e | ForEach-Object { $_.conn }) -join ',') fehler=$($errs -join ' | ')" }

    Clear-MockLog
    $null = Send-Gw 8104 '/v1/messages' $quick
    $null = Send-Gw 8104 '/v1/messages' $quick
    $e = @(Get-MockEntries)
    if ($e.Count -eq 2 -and $e[0].conn -ne $e[1].conn) { Pass 'LLM_GATEWAY_UPSTREAM_IDLE_MS=0: jede Anfrage auf frischer Verbindung' }
    else { Fail "Schalter 0: conns=$(@($e | ForEach-Object { $_.conn }) -join ',')" }

    # (f) Privacy: Kanarien + Schluessel nie im Journal (inkl. kaputtem JSON)
    Write-Host '  (f) Privacy: Prompt-Inhalt und Schluessel nie im Journal'
    $res = Send-Gw 8095 '/v1/messages' ('{"model":"x","messages":[{"role":"user","content":"' + $Canary + '"}')   # kaputtes JSON
    $all = @(Get-UnitJournal $Units.gw) + @(Get-UnitJournal $Units.dead) + @(Get-UnitJournal $Units.ka) + @((Invoke-InU $Units.gw @('cat', "$UsageDir/usage.jsonl")).Output)
    $leak = @($all | Where-Object { $_ -match 'CANARY' })
    if ($leak.Count -eq 0 -and (@($all) -match '"code":"parse_error"')) { Pass 'kein Inhalt/Schluessel im Journal + usage.jsonl, kaputtes JSON nur als parse_error' }
    else { Fail "Journal enthaelt Inhalt/Schluessel: $($leak -join ' | ')" }

    # (i) ungueltiges Anfrage-Ziel ('//host/…') -> 400, Prozess lebt weiter (kein uncaughtException-Neustart)
    Write-Host '  (i) ungueltiges Anfrage-Ziel -> 400, Dienst laeuft weiter'
    $pidBefore = Get-UnitIdentity $Units.gw
    $r = Invoke-InC @('curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--request-target', '//evil.example/v1/messages', '-X', 'POST', 'http://127.0.0.1:8095/')
    $pidAfter = Get-UnitIdentity $Units.gw
    if ((($r.Output -join '').Trim()) -eq '400' -and $pidBefore -eq $pidAfter -and $pidAfter -ne '0' -and $pidAfter -notmatch '^false') { Pass '400 + gleicher Prozess' }
    else { Fail "Status=$($r.Output -join '') PID $pidBefore -> $pidAfter" }

    # (h) echter Upstream, gratis (count_tokens)
    Write-Host '  (h) echter Upstream: /v1/messages/count_tokens (kostenlos)'
    $envFile = Join-Path $RepoRoot '.env'
    $realKey = $null
    if (Test-Path $envFile) {
        $line = Read-DotEnvLines $envFile | Where-Object { $_ -match '^\s*TEST_ANTHROPIC_API_KEY=' } | Select-Object -First 1
        if ($line) { $realKey = ($line -split '=', 2)[1].Trim() }
    }
    if (-not $realKey) { Skip 'TEST_ANTHROPIC_API_KEY fehlt in .env' }
    elseif ($realKey -eq 'ci-dummy-key') { Skip 'erfundener Schluessel (CI free-gates.yml), kein Fall gegen die echte API' }
    else {
        Start-TestUnit $Units.real @('LLM_GATEWAY_PORT=8098') $GwJs 8098
        $res = Send-Gw 8098 '/v1/messages/count_tokens' (ConvertTo-Body ([ordered]@{ model = 'claude-haiku-5-5'; messages = @(@{ role = 'user'; content = 'Hallo' }) })) $realKey
        $jr = @(Get-UnitJournal $Units.real)
        $keyLeak = @($jr | Where-Object { $_.Contains($realKey) })
        if ($res.Status -eq '200' -and $res.Body -match '"input_tokens"\s*:\s*[1-9]' -and $keyLeak.Count -eq 0) { Pass 'TLS/Host/Auth/Kompression ok (count_tokens 200)' }
        else { Fail "Status=$($res.Status) body=$($res.Body.Substring(0, [Math]::Min(200, $res.Body.Length)))" }
    }

    # (m) Telegram-Relay
    Write-Host '  (m) Telegram-Relay: Allowlist, Token-Form, Reaktion, Sticker Upload -> file_id, kein Leck'
    $TgLog = '/tmp/gwtest_tg.jsonl'
    $TgToken = '12345:test-fake-telegram-bot-token-000000'
    if (-not $IsCompose) { Invoke-InC @('sh', '-c', ": > $TgLog") | Out-Null }
    Start-TestUnit $Units.tgmock @('N8NTEST_MOCK_TG_PORT=8103', "N8NTEST_MOCK_TG_LOG=$TgLog") "$TgDir/server.js" 8103 `
        -Files @{ (Join-Path $RepoRoot 'tests\mock_telegram\server.js') = "$TgDir/server.js" }
    Start-TestUnit $Units.tg @('LLM_GATEWAY_PORT=8102', 'LLM_GATEWAY_UPSTREAM=http://127.0.0.1:8096', 'LLM_GATEWAY_KEEPALIVE_HOURS=0',
        'LLM_GATEWAY_TELEGRAM_API=http://127.0.0.1:8103', "LLM_GATEWAY_STICKER_DIR=$StickerDir") $GwJs 8102
    function Send-Tg([string]$Path, [string]$RawBody, [string]$Token = $TgToken) {
        $script:reqN++
        $hostFile = Join-Path $env:TEMP "gwtest_tg_$($script:reqN).json"
        [System.IO.File]::WriteAllText($hostFile, $RawBody, $Utf8NoBom)
        $inC = "/tmp/gwtest_tg_$($script:reqN).json"
        Invoke-Native docker @('cp', $hostFile, "${Container}:$inC") | Out-Null
        Remove-Item $hostFile -ErrorAction SilentlyContinue
        $cfg = "header = `"x-telegram-bot-token: $Token`"`nheader = `"content-type: application/json`"`n"
        $r = Invoke-Native docker @('exec', '-i', $Container, 'curl', '-s', '-K', '-', '-o', '/tmp/gwtest_tg_resp', '-w', '%{http_code}',
            '-X', 'POST', "http://127.0.0.1:8102$Path", '--data-binary', "@$inC") -StdIn $cfg
        $body = ((Invoke-InC @('cat', '/tmp/gwtest_tg_resp')).Output -join "`n")
        Invoke-InC @('rm', '-f', $inC, '/tmp/gwtest_tg_resp') | Out-Null
        return [pscustomobject]@{ Status = (($r.Output -join '').Trim()); Body = $body }
    }
    function Get-TgEntries { @((Invoke-InU $Units.tgmock @('cat', $TgLog)).Output | Where-Object { $_ -match '"method"' } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.method -ne '__start' }) }

    $res = Send-Tg '/__telegram/setMessageReaction' '{"chat_id":"4242","message_id":77}'
    $e = @(Get-TgEntries)
    if ($res.Status -eq '200' -and $res.Body -match '"ok":true' -and $e.Count -eq 1 -and $e[0].method -eq 'setMessageReaction' -and
        $e[0].body.message_id -eq 77 -and $e[0].body.reaction[0].emoji -eq [string][char]0x2764) { Pass 'Reaktion ❤ (ohne VS16) an Telegram durchgereicht' }
    else { Fail "Reaktion: Status=$($res.Status) body=$($res.Body) log=$($e | ConvertTo-Json -Compress -Depth 6)" }

    Clear-MockLog
    $res = Send-Tg '/__telegram/sendMessage' '{"chat_id":"4242","text":"x"}'
    $res2 = Send-Tg '/__telegram/setMessageReaction?x=1' '{"chat_id":"4242","message_id":1}'
    $res3 = Send-Tg '/__telegram/setMessageReaction/x' '{"chat_id":"4242","message_id":1}'
    if ($res.Status -eq '404' -and $res2.Status -eq '404' -and $res3.Status -eq '404' -and @(Get-MockEntries).Count -eq 0 -and @(Get-TgEntries).Count -eq 1) { Pass 'nicht erlaubte Methode/Query/Pfad -> abgelehnt, nichts an Anthropic oder Telegram' }
    else { Fail "Allowlist: $($res.Status)/$($res2.Status)/$($res3.Status) anthropic=$(@(Get-MockEntries).Count) tg=$(@(Get-TgEntries).Count)" }

    $res = Send-Tg '/__telegram/setMessageReaction' '{"chat_id":"4242","message_id":1}' 'kaputt/../x'
    $res2 = Send-Tg '/__telegram/setMessageReaction' '{"chat_id":"4242","message_id":1,"emoji":"💩"}'
    if ($res.Status -eq '400' -and $res2.Status -eq '400' -and @(Get-TgEntries).Count -eq 1) { Pass 'kaputtes Token / nicht erlaubtes Emoji -> 400, kein Aufruf' }
    else { Fail "Token/Emoji: $($res.Status)/$($res2.Status)" }

    # Lebenszeichen + Stimmungen (agent.fn_claim_reaction): 👀 🙏 😁 kommen durch (Zeichen per Codepoint, Datei-Kodierung egal)
    $tgBefore = @(Get-TgEntries).Count   # Clear-MockLog leert nur die Anthropic-Attrappe
    $okAll = $true
    foreach ($cp in @(0x1F440, 0x1F64F, 0x1F601)) {
        $em = [char]::ConvertFromUtf32($cp)
        $r = Send-Tg '/__telegram/setMessageReaction' ('{"chat_id":"4242","message_id":5,"emoji":"' + $em + '"}')
        $last = @(Get-TgEntries) | Select-Object -Last 1
        if ($r.Status -ne '200' -or -not $last -or $last.body.reaction[0].emoji -ne $em) { $okAll = $false; Write-Host "  U+$('{0:X}' -f $cp): $($r.Status)" }
    }
    $tgNew = @(Get-TgEntries).Count - $tgBefore
    if ($okAll -and $tgNew -eq 3) { Pass 'Reaktionen 👀 🙏 😁 durchgereicht' } else { Fail "neue Reaktionen: $tgNew statt 3 Telegram-Aufrufe" }

    $res = Send-Tg '/__telegram/sendSticker' '{"chat_id":"4242","sticker":"butler_top"}'
    $res2 = Send-Tg '/__telegram/sendSticker' '{"chat_id":"4242","sticker":"butler_top"}'
    $st = @(Get-TgEntries | Where-Object { $_.method -eq 'sendSticker' })
    if ($res.Status -eq '200' -and $res2.Status -eq '200' -and $st.Count -eq 2 -and $st[0].body.sticker_file -eq 'butler_top.webp' -and
        [string]$st[0].body.chat_id -eq '4242' -and $st[1].body.sticker -eq 'mock_fid_butler_top.webp') { Pass 'Sticker: erst Upload (Datei aus dem Ordner), dann file_id' }
    else { Fail "Sticker: $($res.Status)/$($res2.Status) log=$($st | ConvertTo-Json -Compress -Depth 6)" }

    $res = Send-Tg '/__telegram/sendSticker' '{"chat_id":"4242","sticker":"../../etc/passwd"}'
    $res2 = Send-Tg '/__telegram/sendSticker' '{"chat_id":"4242","sticker":"pirate_hallo"}'
    if ($res.Status -eq '400' -and $res2.Status -eq '404') { Pass 'Sticker-Name ausserhalb des Musters -> 400, fehlende Datei -> 404' }
    else { Fail "Sticker-Name: $($res.Status)/$($res2.Status)" }

    $jr = @(Get-UnitJournal $Units.tg)
    if (@($jr | Where-Object { $_.Contains('test-fake-telegram-bot-token') }).Count -eq 0) { Pass 'Bot-Token nie im Journal' } else { Fail 'Bot-Token im Journal' }
    $h = $null
    $hr = Invoke-InC @('curl', '-fsS', 'http://127.0.0.1:8102/__health')
    try { $h = ($hr.Output -join '') | ConvertFrom-Json } catch { }
    if ($h -and $h.telegram.upstream -eq 'http://127.0.0.1:8103' -and $h.telegram.sticker_dir -eq $true) { Pass '/__health meldet Telegram-Upstream + Sticker-Ordner' }
    else { Fail "health: $($hr.Output -join '')" }

    # Produktiver Gateway gesund?
    $h = Get-LlmGatewayHealth -Container $Container
    if ($h -and $h.ok) { Pass "produktiver Gateway gesund (upstream $($h.upstream), static_ttl $($h.static_ttl))" } else { Fail 'produktiver Gateway /__health nicht ok' }

    # (n) Verbund: der echte Gateway-Container (nicht eine Wegwerf-Einheit): ein kaputter Body mit Pruefinhalt erreicht sein Log nicht
    # (nur der feste Code parse_error; der Body geht roh an den Upstream weiter, hier die Attrappe des Verbunds, darum nur bei lokalem
    # Upstream); nach einem Neustart liest er seine Umgebung aus gateway.env neu und ist gesund.
    if ($IsCompose) {
        Write-Host '  (n) Verbund: echter Gateway-Container: Pruefinhalt nie im Log, Neustart gesund'
        if (-not ($h -and "$($h.upstream)" -match '^http://127\.0\.0\.1:')) { Fail "echter Gateway hat keinen lokalen Upstream ($($h.upstream)): kein Pruefinhalt gesendet" }
        else {
            $resReal = Send-Gw 8090 '/v1/messages' ('{"model":"x","messages":[{"role":"user","content":"' + $Canary + '"}')
            Restart-TestLlmGateway -Container $Container
            $h2 = Get-LlmGatewayHealth -Container $Container
            $realLog = @((Invoke-Native docker @('logs', $target.Gateway)).Output)
            $canaryLines = @($realLog | Where-Object { $_ -match 'CANARY' }).Count
            if ($h2 -and $h2.ok -and $canaryLines -eq 0 -and (@($realLog) -match '"code":"parse_error"')) { Pass "$($target.Gateway): kaputter Body nur als parse_error geloggt, kein Pruefinhalt; nach Neustart gesund" }
            else { Fail "echter Gateway: Status=$($resReal.Status) health=$($h2 | ConvertTo-Json -Compress) canary-zeilen=$canaryLines" }
        }
    }
} finally {
    if ($Verbose) { Write-Host ((Get-UnitJournal $Units.gw) -join "`n") -ForegroundColor DarkGray }
    Stop-TestUnits
}

Write-Host ''
Write-Host ('-' * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed bestanden, $failed fehlgeschlagen, $skipped uebersprungen." -ForegroundColor $color
exit $failed
