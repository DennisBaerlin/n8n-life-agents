#Requires -Version 5.1
# enable_mock_telegram.ps1 — den Mock-Telegram-Server in der laufenden Test-n8n-Instanz scharf schalten
# (Teststrategie Phase 5). Operiert auf einem BEREITS hochgefahrenen Substrat
# (scripts/dev/bootstrap_test_n8n.ps1) — bewusst getrennt, damit der byte-identische Install-Pfad und der
# schon reviewte bootstrap-Treiber unberuehrt bleiben (kleinerer Blast-Radius).
#
# Was es tut (idempotent):
#   1) tests/mock_telegram/server.js in den Container kopieren (-> /opt/mock_telegram/server.js).
#   2) Den Mock als transiente systemd-unit `n8ntest-mock-telegram` starten (127.0.0.1:<port>,
#      Node ist durch n8n garantiert) + Health-Probe.
#   3) Den Telegram-baseUrl der Credential 'Telegram account' per REST-PATCH auf den Mock umbiegen
#      (`PATCH /api/v1/credentials/{id}`, data={accessToken, baseUrl}). Damit gehen ALLE Telegram-API-
#      Calls der Workflows an den Mock statt an api.telegram.org — inject_credentials.sh bleibt
#      byte-identisch (keine Provisioning-Aenderung).
#   3b) Den Telegram-Relay des LLM-Gateways (Herz-Reaktion + Persona-Sticker, Kopf von provisioning/llm_gateway/server.js)
#      per eigenem LAUFZEIT-Drop-in (/run/systemd/system/<gateway>.service.d/telegram-mock.conf,
#      LLM_GATEWAY_TELEGRAM_API=<mock>) + Neustart auf den Mock biegen; geprueft per /__health.telegram.upstream.
#      Eigener Dateiname: enable_mock_llm.ps1 schreibt mock.conf nur mit seiner eigenen Zeile. /run ist fluechtig ->
#      nach einem Container-Neustart bzw. bootstrap ohne -Reset dieses Skript erneut laufen lassen.
#   4) Einen `mock_telegram`-Block ins State-File schreiben (Port/Log/Unit) fuer die Tier-/Verify-Skripte.
#
# -Down: Mock-Unit stoppen + baseUrl zurueck auf https://api.telegram.org patchen + Gateway-Drop-in weg + State-Block entfernen.
#
# Vorbedingung: laufendes Substrat (.local/n8ntest_state.<container>.json) + TEST_TELEGRAM_BOT_TOKEN in .env
# (die Credential muss existieren — inject_credentials legt sie nur bei vorhandenem Token an; der Mock
# selbst ignoriert den Token, aber der Telegram-Node braucht eine gebundene Credential).
param(
    [switch]$Down,
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

$MockPort   = if ($env:N8NTEST_MOCK_TG_PORT) { $env:N8NTEST_MOCK_TG_PORT } else { '8089' }
$MockUrl    = "http://127.0.0.1:$MockPort"
$MockLog    = '/tmp/mock_telegram.jsonl'
$Unit       = 'n8ntest-mock-telegram'
$ServerHost = Join-Path $RepoRoot 'tests\mock_telegram\server.js'
$ServerInC  = '/opt/mock_telegram/server.js'
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

# --- Telegram-Credential-ID (Laufzeit-id; inject_credentials remappt die getrackte id) finden -------
function Get-TelegramCredId {
    $resp = Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials?limit=250" -Headers $Headers -Method Get
    $c = $resp.data | Where-Object { $_.type -eq 'telegramApi' -and $_.name -eq 'Telegram account' } | Select-Object -First 1
    if (-not $c) { $c = $resp.data | Where-Object { $_.type -eq 'telegramApi' } | Select-Object -First 1 }
    return $c.id
}

# Set-TelegramBaseUrl — baseUrl (+ accessToken, vollstaendige data fuer robustes Replace) patchen.
function Set-TelegramBaseUrl {
    param([Parameter(Mandatory)][string]$CredId, [Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Token)
    $body = @{ name = 'Telegram account'; type = 'telegramApi'; data = @{ accessToken = $Token; baseUrl = $BaseUrl } } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials/$CredId" -Headers $Headers -Method Patch `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

# --- .env: TEST_TELEGRAM_BOT_TOKEN (Credential-data verlangt accessToken beim PATCH) -----------------
function Get-EnvValue([string]$name) {
    $line = (Get-Content "$RepoRoot\.env" | Where-Object { $_ -match "^\s*$([regex]::Escape($name))=" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $v = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}
$Token = Get-EnvValue 'TEST_TELEGRAM_BOT_TOKEN'
if (-not $Token) {
    throw "TEST_TELEGRAM_BOT_TOKEN fehlt in .env — ohne Token existiert die 'Telegram account'-Credential nicht (inject_credentials ueberspringt sie) und das Gate kann nicht senden."
}

# --- State lesen/schreiben (mock_telegram-Block additiv) ---------------------------------------------
function Read-State { [System.IO.File]::ReadAllText($StateFile, $Utf8NoBom) | ConvertFrom-Json }
function Write-StateMock([object]$state, [object]$mockBlock) {
    $ordered = [ordered]@{}
    foreach ($p in $state.PSObject.Properties) { if ($p.Name -ne 'mock_telegram') { $ordered[$p.Name] = $p.Value } }
    if ($null -ne $mockBlock) { $ordered['mock_telegram'] = $mockBlock }
    [System.IO.File]::WriteAllText($StateFile, ([pscustomobject]$ordered | ConvertTo-Json), $Utf8NoBom)
}

# --- Gateway-Telegram-Relay per Laufzeit-Drop-in umbiegen ($Api = $null -> Drop-in weg = echtes Telegram) ------------
$GwUnit   = 'lifeagents-llm-gateway'
$GwDropIn = "/run/systemd/system/$GwUnit.service.d/telegram-mock.conf"
function Set-GatewayTelegramApi {
    param([string]$Api)
    if ($Api) {
        $conf = "[Service]`nEnvironment=LLM_GATEWAY_TELEGRAM_API=$Api`n"
        $r = Invoke-Native docker @('exec',$Container,'sh','-c',"mkdir -p `$(dirname '$GwDropIn') && printf '%s' '$conf' > '$GwDropIn'")
    } else {
        $r = Invoke-Native docker @('exec',$Container,'rm','-f',$GwDropIn)
    }
    if ($r.Code -ne 0) { throw "Gateway-Drop-in (Telegram) schreiben/entfernen fehlgeschlagen: $($r.Output -join "`n")" }
    Invoke-Native docker @('exec',$Container,'systemctl','daemon-reload') | Out-Null
    $r = Invoke-Native docker @('exec',$Container,'systemctl','restart',$GwUnit)
    if ($r.Code -ne 0) { throw "Neustart $GwUnit fehlgeschlagen (Substrat mit Gateway gebaut? sonst -Reset): $($r.Output -join "`n")" }
    $want = if ($Api) { $Api } else { 'https://api.telegram.org' }
    for ($i = 0; $i -lt 20; $i++) {
        $h = Get-LlmGatewayHealth -Container $Container
        if ($h -and $h.telegram -and [string]$h.telegram.upstream -eq $want) { return }
        Start-Sleep -Milliseconds 300
    }
    throw "LLM-Gateway meldet nicht den erwarteten Telegram-Upstream '$want' (journalctl -u $GwUnit)."
}

$credId = Get-TelegramCredId
if (-not $credId) { throw "Keine telegramApi-Credential gefunden — wurde das Substrat mit TEST_TELEGRAM_BOT_TOKEN gebaut?" }

# --- Teardown ---------------------------------------------------------------------------------------
if ($Down) {
    Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
    Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
    Set-TelegramBaseUrl -CredId $credId -BaseUrl 'https://api.telegram.org' -Token $Token
    Set-GatewayTelegramApi $null
    if (Test-Path $StateFile) { Write-StateMock (Read-State) $null }
    Write-Host "Mock-Telegram deaktiviert: Unit gestoppt, baseUrl + Gateway-Relay -> https://api.telegram.org, State-Block entfernt."
    return
}

# --- 1) server.js in den Container kopieren ---------------------------------------------------------
if (-not (Test-Path $ServerHost)) { throw "Mock-Server nicht gefunden: $ServerHost" }
$r = Invoke-Native docker @('exec',$Container,'mkdir','-p','/opt/mock_telegram')
if ($r.Code -ne 0) { throw "mkdir /opt/mock_telegram fehlgeschlagen: $($r.Output -join "`n")" }
$r = Invoke-Native docker @('cp',$ServerHost,"${Container}:$ServerInC")
if ($r.Code -ne 0) { throw "docker cp server.js fehlgeschlagen: $($r.Output -join "`n")" }
# Echte Test-Dokumente (tests/mock_telegram/docs, make_doc_fixtures.ps1) -> /opt/mock_telegram/docs; der Mock liefert
# sie fuer die passenden file_ids aus (Echt-LLM-Tier liest so ein lesbares Dokument statt des 1x1-PNG).
$DocsHost = Join-Path $RepoRoot 'tests\mock_telegram\docs'
if (Test-Path $DocsHost) {
    $r = Invoke-Native docker @('cp',"$DocsHost\.","${Container}:/opt/mock_telegram/docs")
    if ($r.Code -ne 0) { throw "docker cp docs/ fehlgeschlagen: $($r.Output -join "`n")" }
}

# --- 2) Mock als transiente systemd-unit starten (Reload: stop+start, um neue server.js zu ziehen) ---
$nodeBin = ((Invoke-Native docker @('exec',$Container,'sh','-c','command -v node')).Output -join '').Trim()
if (-not $nodeBin) { throw "node im Container nicht gefunden (n8n bringt Node mit — Substrat ok?)." }
Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
Write-Host "Starte Mock-Telegram (systemd-unit $Unit, 127.0.0.1:$MockPort) ..."
$r = Invoke-Native docker @('exec',$Container,'systemd-run',"--unit=$Unit",'--collect',
    "--setenv=N8NTEST_MOCK_TG_PORT=$MockPort","--setenv=N8NTEST_MOCK_TG_LOG=$MockLog",
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
    throw "Mock-Telegram wurde nicht bereit (Health-Probe Timeout). journalctl:`n$($jr.Output -join "`n")"
}

# --- 3) Telegram-baseUrl auf den Mock umbiegen ------------------------------------------------------
Set-TelegramBaseUrl -CredId $credId -BaseUrl $MockUrl -Token $Token
Write-Host "Telegram-baseUrl -> $MockUrl (Credential $credId gepatcht)."
Set-GatewayTelegramApi $MockUrl
Write-Host "Gateway-Telegram-Relay -> $MockUrl (Drop-in $GwDropIn)."

# --- 4) State-Block schreiben -----------------------------------------------------------------------
$mockBlock = [ordered]@{ port = [int]$MockPort; url = $MockUrl; log = $MockLog; unit = $Unit; cred_id = $credId }
Write-StateMock (Read-State) $mockBlock

Write-Host ""
Write-Host "============================================================"
Write-Host "  Mock-Telegram aktiv"
Write-Host "  Unit:      $Unit  (127.0.0.1:$MockPort, im Container)"
Write-Host "  Log:       $MockLog  (lesen: Get-MockTelegramRequests)"
Write-Host "  baseUrl:   Credential 'Telegram account' -> $MockUrl"
Write-Host ""
Write-Host "  HITL-Gate deterministisch pruefen:  .\scripts\dev\hitl_gate_test.ps1"
Write-Host "  deaktivieren:                       .\scripts\dev\enable_mock_telegram.ps1 -Down"
Write-Host "============================================================"
