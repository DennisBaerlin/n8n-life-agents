#Requires -Version 5.1
# enable_mock_llm.ps1 — den Mock-LLM-Server in der laufenden Test-n8n-Instanz scharf schalten
# (Teststrategie Phase 6). Operiert auf einem BEREITS hochgefahrenen Substrat
# (scripts/dev/bootstrap_test_n8n.ps1) — kein Provisioning-Eingriff, kleiner Blast-Radius.
#
# Was es tut (idempotent):
#   1) tests/mock_llm/{server.js,scenarios.json} in den Container kopieren (-> /opt/mock_llm/).
#   2) Den Mock als transiente systemd-unit `n8ntest-mock-llm` starten (127.0.0.1:<port>, Node ist
#      durch n8n garantiert) + Health-Probe.
#   3a) Den UPSTREAM des LLM-Gateways (provisioning/llm_gateway) auf den Stub biegen: die Anthropic-Credential
#      zeigt fest auf den Gateway (inject_credentials.sh) -> ein systemd-LAUFZEIT-Drop-in
#      (/run/systemd/system/<unit>.d/mock.conf, LLM_GATEWAY_UPSTREAM=<stub>) + Neustart. Damit sprechen ALLE
#      Claude-Aufrufe (Chat-Agenten UND die direkten HTTP-Knoten: Websuche, Monitor, Scorer, Vision) mit dem Stub,
#      und der Gratis-Tier testet den Gateway (Haltepunkte, Messung) gleich mit. /run ist fluechtig -> ein
#      Container-Neustart faellt sicher auf die echte API zurueck; die Suiten pruefen den Upstream
#      (Assert-LlmGatewayUpstream), bevor sie feuern.
#   3b) OPTIONAL den `host` der Credential 'Google Gemini(PaLM) Api account' (googlePalmApi) auf den Stub
#      biegen — nur die Sprach-Transkription nutzt sie noch. Der Stub transkribiert nur die markierten Test-Dateien
#      (Marker-Liste GEMINI_FILES in tests/mock_llm/server.js) und beantwortet alles andere mit 404 -> eine
#      versehentliche Transkription im Test landet im Fehlerweg (voice_unavailable) statt bei Google.
#      Fehlt TEST_GOOGLE_API_KEY, existiert die Credential nicht -> uebersprungen (der Fehlerweg greift ohnehin).
#   4) Einen `mock_llm`-Block ins State-File schreiben (Port/Log/Unit/gateway_upstream/cred_id).
#
# -Down: Mock-Unit stoppen + Drop-in entfernen (Gateway-Upstream zurueck auf https://api.anthropic.com) +
#   (falls gepatcht) Gemini-host zurueck auf https://generativelanguage.googleapis.com + State-Block entfernen.
# -UpdateScenarios: NUR scenarios.json neu kopieren (der Stub liest sie pro Request frisch -> kein Neustart).
#
# Vorbedingung: laufendes Substrat (.local/n8ntest_state.<container>.json). TEST_GOOGLE_API_KEY ist optional (nur fuer 3b).
param(
    [switch]$Down,
    [switch]$UpdateScenarios,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container
$N8nUrl    = $conn.Url
$ApiKey    = $conn.ApiKey
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "Kein N8N_API_KEY im State — die Credential-Umbiegung braucht die REST-API. Substrat neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset"
}

$MockPort   = if ($env:N8NTEST_MOCK_LLM_PORT) { $env:N8NTEST_MOCK_LLM_PORT } else { '8088' }
$MockUrl    = "http://127.0.0.1:$MockPort"
$MockLog    = '/tmp/mock_llm.jsonl'
$RealHost   = 'https://generativelanguage.googleapis.com'
$GwUnit     = 'lifeagents-llm-gateway'
$GwDropIn   = "/run/systemd/system/$GwUnit.service.d/mock.conf"
$Unit       = 'n8ntest-mock-llm'
$ServerHost = Join-Path $RepoRoot 'tests\mock_llm\server.js'
$ScnHost    = Join-Path $RepoRoot 'tests\mock_llm\scenarios.json'
$ServerInC  = '/opt/mock_llm/server.js'
$ScnInC     = '/opt/mock_llm/scenarios.json'
$StateFile  = Get-TestN8nStateFile
$Headers    = @{ 'X-N8N-API-KEY' = $ApiKey }

# Invoke-Native — natives Tool, stdout+stderr + Exit-Code (EAP-Quirk wie die uebrigen dev-Treiber).
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

# --- googlePalmApi-Credential-ID (Laufzeit-id; inject_credentials remappt die getrackte id) finden ----
function Get-GeminiCredId {
    $resp = Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials?limit=250" -Headers $Headers -Method Get
    $c = $resp.data | Where-Object { $_.type -eq 'googlePalmApi' -and $_.name -eq 'Google Gemini(PaLM) Api account' } | Select-Object -First 1
    if (-not $c) { $c = $resp.data | Where-Object { $_.type -eq 'googlePalmApi' } | Select-Object -First 1 }
    return $c.id
}

# Set-GeminiHost — host (+ apiKey + allowedDomains, vollstaendige data fuer robustes Replace) patchen.
function Set-GeminiHost {
    param([Parameter(Mandatory)][string]$CredId, [Parameter(Mandatory)][string]$HostUrl, [Parameter(Mandatory)][string]$ApiKeyVal)
    $body = @{ name = 'Google Gemini(PaLM) Api account'; type = 'googlePalmApi'; data = @{ host = $HostUrl; apiKey = $ApiKeyVal; allowedDomains = '' } } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials/$CredId" -Headers $Headers -Method Patch `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

# --- LLM-Gateway-Upstream per Laufzeit-Drop-in umbiegen ($Upstream = $null -> Drop-in weg = echte API) -----
# Prueft danach /__health.upstream (Assert statt Hoffnung): ein falscher Upstream kostete im Gratis-Tier Credits.
function Set-GatewayUpstream {
    param([string]$Upstream)
    if ($Upstream) {
        $conf = "[Service]`nEnvironment=LLM_GATEWAY_UPSTREAM=$Upstream`n"
        $r = Invoke-Native docker @('exec',$Container,'sh','-c',"mkdir -p `$(dirname '$GwDropIn') && printf '%s' '$conf' > '$GwDropIn'")
    } else {
        $r = Invoke-Native docker @('exec',$Container,'rm','-f',$GwDropIn)
    }
    if ($r.Code -ne 0) { throw "Gateway-Drop-in schreiben/entfernen fehlgeschlagen: $($r.Output -join "`n")" }
    Invoke-Native docker @('exec',$Container,'systemctl','daemon-reload') | Out-Null
    $r = Invoke-Native docker @('exec',$Container,'systemctl','restart',$GwUnit)
    if ($r.Code -ne 0) { throw "Neustart $GwUnit fehlgeschlagen (Substrat mit Gateway gebaut? sonst -Reset): $($r.Output -join "`n")" }
    $want = if ($Upstream) { $Upstream } else { 'https://api.anthropic.com' }
    for ($i = 0; $i -lt 20; $i++) {
        $h = Get-LlmGatewayHealth -Container $Container
        if ($h -and [string]$h.upstream -eq $want) { return }
        Start-Sleep -Milliseconds 300
    }
    throw "LLM-Gateway meldet nicht den erwarteten Upstream '$want' (journalctl -u $GwUnit)."
}

# --- .env: TEST_GOOGLE_API_KEY optional (Credential-data verlangt apiKey beim PATCH; der Revert stellt ihn wieder her) ----
function Get-EnvValue([string]$name) {
    if (-not (Test-Path "$RepoRoot\.env")) { return $null }
    $line = (Get-Content "$RepoRoot\.env" | Where-Object { $_ -match "^\s*$([regex]::Escape($name))=" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $v = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}
$GoogleKey = Get-EnvValue 'TEST_GOOGLE_API_KEY'   # optional: nur die Transkriptions-Credential (3b)

# --- State lesen/schreiben (mock_llm-Block additiv) --------------------------------------------------
function Read-State { [System.IO.File]::ReadAllText($StateFile, $Utf8NoBom) | ConvertFrom-Json }
function Write-StateMock([object]$state, [object]$mockBlock) {
    $ordered = [ordered]@{}
    foreach ($p in $state.PSObject.Properties) { if ($p.Name -ne 'mock_llm') { $ordered[$p.Name] = $p.Value } }
    if ($null -ne $mockBlock) { $ordered['mock_llm'] = $mockBlock }
    [System.IO.File]::WriteAllText($StateFile, ([pscustomobject]$ordered | ConvertTo-Json -Depth 10), $Utf8NoBom)
}

# --- Server/Scenarios in den Container kopieren (Helfer; -UpdateScenarios nutzt nur den Scenarios-Teil) ----
function Copy-Scenarios {
    if (-not (Test-Path $ScnHost)) { throw "Scenarios nicht gefunden: $ScnHost" }
    $r = Invoke-Native docker @('cp',$ScnHost,"${Container}:$ScnInC")
    if ($r.Code -ne 0) { throw "docker cp scenarios.json fehlgeschlagen: $($r.Output -join "`n")" }
}

# Gemini-Credential optional (nur Transkription): nur wenn Key da UND Credential vorhanden.
$credId = $null
if ($GoogleKey) { $credId = Get-GeminiCredId }

# --- -UpdateScenarios: nur Scenarios neu kopieren (Stub liest sie pro Request frisch) ---------------
if ($UpdateScenarios) {
    Copy-Scenarios
    Write-Host "scenarios.json neu kopiert -> $ScnInC (Stub liest pro Request frisch, kein Neustart noetig)."
    return
}

# --- Teardown ---------------------------------------------------------------------------------------
if ($Down) {
    Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
    Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
    $stateBefore = if (Test-Path $StateFile) { Read-State } else { $null }
    Set-GatewayUpstream -Upstream $null
    Write-Host "LLM-Gateway-Upstream -> https://api.anthropic.com (Drop-in entfernt)."
    if ($credId) {
        Set-GeminiHost -CredId $credId -HostUrl $RealHost -ApiKeyVal $GoogleKey
        Write-Host "Gemini-host -> $RealHost (Transkriptions-Credential $credId zurueckgesetzt)."
    } elseif ($stateBefore -and $stateBefore.mock_llm -and $stateBefore.mock_llm.cred_id) {
        # Beim Aktivieren wurde die Gemini-Credential gepatcht, jetzt fehlt der Key zum Revert -> nicht still lassen.
        Write-Host "[WARN] Gemini-Credential ($($stateBefore.mock_llm.cred_id)) konnte NICHT zurueckgesetzt werden (TEST_GOOGLE_API_KEY fehlt). Manuell auf $RealHost setzen." -ForegroundColor Yellow
    }
    if ($stateBefore) { Write-StateMock $stateBefore $null }
    Write-Host "Mock-LLM deaktiviert: Unit gestoppt, Endpunkte zurueckgesetzt, State-Block entfernt."
    return
}

# --- 1) server.js + scenarios.json in den Container kopieren ----------------------------------------
if (-not (Test-Path $ServerHost)) { throw "Mock-Server nicht gefunden: $ServerHost" }
$r = Invoke-Native docker @('exec',$Container,'mkdir','-p','/opt/mock_llm')
if ($r.Code -ne 0) { throw "mkdir /opt/mock_llm fehlgeschlagen: $($r.Output -join "`n")" }
$r = Invoke-Native docker @('cp',$ServerHost,"${Container}:$ServerInC")
if ($r.Code -ne 0) { throw "docker cp server.js fehlgeschlagen: $($r.Output -join "`n")" }
Copy-Scenarios

# --- 2) Mock als transiente systemd-unit starten (Reload: stop+start, um neue server.js zu ziehen) --
$nodeBin = ((Invoke-Native docker @('exec',$Container,'sh','-c','command -v node')).Output -join '').Trim()
if (-not $nodeBin) { throw "node im Container nicht gefunden (n8n bringt Node mit — Substrat ok?)." }
Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
Write-Host "Starte Mock-LLM (systemd-unit $Unit, 127.0.0.1:$MockPort) ..."
$r = Invoke-Native docker @('exec',$Container,'systemd-run',"--unit=$Unit",'--collect',
    "--setenv=MOCK_LLM_PORT=$MockPort","--setenv=MOCK_LLM_LOG=$MockLog","--setenv=MOCK_LLM_SCENARIOS=$ScnInC",
    $nodeBin,$ServerInC)
if ($r.Code -ne 0) { throw "systemd-run $Unit fehlgeschlagen: $($r.Output -join "`n")" }

# Health-Probe (im Container gegen die Loopback) -----------------------------------------------------
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    $p = Invoke-Native docker @('exec',$Container,'sh','-c',"curl -sf http://127.0.0.1:$MockPort/__health >/dev/null 2>&1 && echo ok || echo no")
    if ((($p.Output -join '').Trim()) -eq 'ok') { $ready = $true; break }
    Start-Sleep -Milliseconds 400
}
if (-not $ready) {
    $jr = Invoke-Native docker @('exec',$Container,'journalctl','-u',$Unit,'--no-pager','-n','20')
    throw "Mock-LLM wurde nicht bereit (Health-Probe Timeout). journalctl:`n$($jr.Output -join "`n")"
}

# --- 3a) LLM-Gateway-Upstream auf den Stub (Pflicht: alle Claude-Aufrufe) ---------------------------
Set-GatewayUpstream -Upstream $MockUrl
Write-Host "LLM-Gateway-Upstream -> $MockUrl (Drop-in $GwDropIn; alle Claude-Aufrufe am Mock)."

# --- 3b) Gemini-host (nur Transkription) optional auf denselben Stub (404 -> voice_unavailable) ----
if ($credId) {
    Set-GeminiHost -CredId $credId -HostUrl $MockUrl -ApiKeyVal $GoogleKey
    Write-Host "Gemini-host -> $MockUrl (Transkriptions-Credential $credId gepatcht; Stub transkribiert nur markierte Testdateien, sonst 404)."
} else {
    Write-Host "Gemini-Credential nicht vorhanden (kein TEST_GOOGLE_API_KEY) -> Transkription laeuft in den Fehlerweg (voice_unavailable)."
}

# --- 4) State-Block schreiben -----------------------------------------------------------------------
$mockBlock = [ordered]@{ port = [int]$MockPort; url = $MockUrl; log = $MockLog; unit = $Unit; cred_id = $credId; gateway_upstream = $MockUrl }
Write-StateMock (Read-State) $mockBlock

Write-Host ""
Write-Host "============================================================"
Write-Host "  Mock-LLM aktiv (LLM-Gateway-Upstream umgebogen)"
Write-Host "  Unit:      $Unit  (127.0.0.1:$MockPort, im Container)"
Write-Host "  Log:       $MockLog  (lesen: Get-MockLlmRequests)"
Write-Host "  Anthropic: LLM-Gateway ($GwUnit) -> $MockUrl"
$gemShown = if ($credId) { "$MockUrl (markierte Testdateien, sonst 404 -> voice_unavailable)" } else { '(keine Credential)' }
Write-Host "  Gemini:    Transkriptions-Credential -> $gemShown"
Write-Host ""
Write-Host "  Routing/Tool-Path deterministisch pruefen:  .\scripts\dev\mock_route_test.ps1"
Write-Host "  Scenarios nachladen:                        .\scripts\dev\enable_mock_llm.ps1 -UpdateScenarios"
Write-Host "  deaktivieren:                               .\scripts\dev\enable_mock_llm.ps1 -Down"
Write-Host "============================================================"
