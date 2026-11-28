#Requires -Version 5.1
# enable_mock_telegram.ps1 — den Mock-Telegram-Server in der laufenden Test-n8n-Instanz scharf schalten
# (Aufruf: .\scripts\dev\enable_mock_telegram.ps1 [-Down]). Operiert auf einem bereits hochgefahrenen
# Substrat (scripts/dev/bootstrap_test_n8n.ps1) — bewusst getrennt, damit der byte-identische Install-Pfad und der
# bootstrap-Treiber unberuehrt bleiben (kleinerer Blast-Radius).
#
# Was es tut (idempotent):
#   1) tests/mock_telegram/server.js in den Container kopieren (-> /opt/mock_telegram/server.js).
#   1b) tests/mock_telegram/docs mitkopieren; CSV-Dateien mit {{date:..}} vorher aufloesen (Bezugstag core.fn_today()).
#   2) Den Mock als transiente systemd-unit `n8ntest-mock-telegram` starten (127.0.0.1:<port>,
#      Node ist durch n8n garantiert) + Health-Probe.
#   3) Den Telegram-baseUrl der Credential 'Telegram account' per REST-PATCH auf den Mock umbiegen
#      (`PATCH /api/v1/credentials/{id}`, data={accessToken, baseUrl}). Damit gehen alle Telegram-API-
#      Calls der Workflows an den Mock statt an api.telegram.org — inject_credentials.sh bleibt
#      byte-identisch (keine Provisioning-Aenderung).
#   3b) Den Telegram-Relay des LLM-Gateways (Herz-Reaktion + Persona-Sticker, Kopf von provisioning/llm_gateway/server.js)
#      per eigenem Laufzeit-Drop-in (/run/systemd/system/<gateway>.service.d/telegram-mock.conf,
#      LLM_GATEWAY_TELEGRAM_API=<mock>) + Neustart auf den Mock biegen; geprueft per /__health.telegram.upstream.
#      Eigener Dateiname: enable_mock_llm.ps1 schreibt mock.conf nur mit seiner eigenen Zeile. /run ist fluechtig ->
#      nach einem Container-Neustart bzw. bootstrap ohne -Reset dieses Skript erneut laufen lassen.
#   3c) Jeden Workflow mit telegramTrigger, dessen Webhook-Route 404 liefert (setWebhook scheiterte beim Deploy), per API
#      unpublish/publish gegen den Mock neu anmelden; Bot-Name per core.fn_set_bot_username('mock_test_bot') setzen.
#   4) Einen `mock_telegram`-Block ins State-File schreiben (Port/Log/Unit) fuer die Tier-/Verify-Skripte.
#
# -Down: Mock-Unit stoppen + baseUrl zurueck auf https://api.telegram.org patchen + Gateway-Drop-in weg + State-Block entfernen.
#
# Im Docker-Verbund (runtime=compose) setzt die Installation Bot-Token (erfunden) und Ziel fuer n8n und Gateway fest auf die
# Attrappe (Test-Weiche LIFEAGENTS_TELEGRAM_API, scripts/lib/test_stack.ps1); hier wird nichts umgebogen: die Test-Dokumente
# (Platzhalter aufgeloest) gehen in einen Ordner im Log-Ordner des Verbunds, die Attrappe <p>-tgmock startet mit ihm neu
# (tests/mock_pod/start_mocks.sh tg, MOCK_TG_DOCS), das Gateway-Ziel wird geprueft; Trigger-Routen und Bot-Name wie unten.
# -Down entfernt Attrappe und Block, die Ziele bleiben.
#
# Vorbedingung: laufendes Substrat (.local/n8ntest_state.<container>.json); das Token ist ein erfundenes (Resolve-TestTelegramToken)
# (die Credential muss existieren — inject_credentials legt sie nur bei vorhandenem Token an; der Mock
# selbst ignoriert den Token, aber der Telegram-Node braucht eine gebundene Credential).
# Exit-Code: 0 = ok; jeder Fehler wirft ($ErrorActionPreference = 'Stop') und bricht das Skript ab (Exit ungleich 0).
param(
    [switch]$Down
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
$Target     = Get-TestN8nTarget -Container $Container

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

# --- Bot-Token (Credential-data verlangt accessToken beim PATCH): classic TEST_TELEGRAM_BOT_TOKEN, Verbund das der Installation --
$Token = Get-TestBotToken -Target $Target
if (-not $Token) {
    throw "Kein Bot-Token fuer die Telegram-Credential ermittelbar (Get-TestBotToken)."
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
    Restart-TestLlmGateway -Container $Container
    $want = if ($Api) { $Api } else { 'https://api.telegram.org' }
    for ($i = 0; $i -lt 20; $i++) {
        $h = Get-LlmGatewayHealth -Container $Container
        if ($h -and $h.telegram -and [string]$h.telegram.upstream -eq $want) { return }
        Start-Sleep -Milliseconds 300
    }
    throw "LLM-Gateway meldet nicht den erwarteten Telegram-Upstream '$want' (journalctl -u $GwUnit)."
}

$credId = Get-TelegramCredId
if (-not $credId) { throw "Keine telegramApi-Credential gefunden — wurde das Substrat mit einem Bot-Token gebaut (Resolve-TestTelegramToken)?" }

# --- Teardown ---------------------------------------------------------------------------------------
if ($Down -and $Target.Runtime -eq 'compose') {
    [void](Invoke-Native docker @('rm', '-fv', "$($Target.Project)-tgmock"))
    Set-TestN8nStateBlock -Name 'mock_telegram' -Block $null
    Write-Host "Mock-Telegram-Attrappe $($Target.Project)-tgmock entfernt; die Ziele bleiben laut Installation auf der Attrappe (Aufrufe scheitern jetzt)."
    return
}
if ($Down) {
    Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
    Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
    Set-TelegramBaseUrl -CredId $credId -BaseUrl 'https://api.telegram.org' -Token $Token
    Set-GatewayTelegramApi $null
    if (Test-Path $StateFile) { Set-TestN8nStateBlock -Name 'mock_telegram' -Block $null }
    Write-Host "Mock-Telegram deaktiviert: Unit gestoppt, baseUrl + Gateway-Relay -> https://api.telegram.org, State-Block entfernt."
    return
}

# Echte Test-Dokumente (tests/mock_telegram/docs, make_doc_fixtures.ps1): der Mock liefert sie fuer die passenden file_ids aus
# (Echt-LLM-Tier liest so ein lesbares Dokument statt des 1x1-PNG). CSV-Test-Dateien mit Datums-Platzhaltern {{date:...}}
# (Zeilen relativ zu heute, z. B. eine Zahlung vom Importtag) loest Write-ResolvedDocs auf (scripts/lib/date_placeholder.ps1),
# Bezugstag = Kalendertag der Datenbank (core.fn_today), mit dem Prepare, setup_sql und verify_sql rechnen (der UTC-Tag wiche
# nachts ab). Der Mock selbst bleibt ohne Abhaengigkeit (jede Kopie von server.js laeuft allein; Waechter: date_placeholder_test).
$DocsHost = Join-Path $RepoRoot 'tests\mock_telegram\docs'
# Write-ResolvedDocs <ordner> -- die Platzhalter-CSVs aufgeloest nach <ordner> schreiben; Rueckgabe = ihre Dateinamen.
function Write-ResolvedDocs([string]$OutDir) {
    . (Join-Path $RepoRoot 'scripts\lib\date_placeholder.ps1')
    $phDocs = @(Get-ChildItem -LiteralPath $DocsHost -Filter '*.csv' | Where-Object {
        [System.IO.File]::ReadAllText($_.FullName, $Utf8NoBom).Contains('{{date:') })
    if (-not $phDocs.Count) { return @() }
    $dbToday = ((Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', 'SELECT core.fn_today();')).Output -join '').Trim()
    if ($dbToday -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "core.fn_today() im Substrat nicht lesbar: '$dbToday'" }
    $day = [datetime]::ParseExact($dbToday, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    foreach ($doc in $phDocs) {
        $txt = Resolve-DatePlaceholder -Text ([System.IO.File]::ReadAllText($doc.FullName, $Utf8NoBom)) -Today $day
        [System.IO.File]::WriteAllText((Join-Path $OutDir $doc.Name), $txt, $Utf8NoBom)
    }
    Write-Host "Test-Dateien mit Datums-Platzhaltern aufgeloest (Bezugstag $dbToday): $(@($phDocs.Name) -join ', ')"
    return @($phDocs.Name)
}

if ($Target.Runtime -eq 'compose') {
    # --- Docker-Verbund: Dokumente-Ordner bauen, Attrappe damit neu starten, Ziel pruefen (gesetzt hat es die Installation) ----
    $MockUrl = $script:TestStackMockSwitches.LIFEAGENTS_TELEGRAM_API
    $MockPort = ([uri]$MockUrl).Port
    $mockC = "$($Target.Project)-tgmock"
    $stackLogDir = Get-TestStackLogDir $Target.Project
    $docsDir = Join-Path $stackLogDir 'tgdocs'
    Remove-Item -LiteralPath $docsDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
    if (Test-Path $DocsHost) {
        Copy-Item -Path (Join-Path $DocsHost '*') -Destination $docsDir -Recurse -Force
        [void](Write-ResolvedDocs $docsDir)
    }
    Write-Host "Starte Mock-Telegram-Attrappe $mockC (Dokumente aus $docsDir) ..."
    Start-TestStackMocks -Names (Get-TestStackNames $Target.Project) -RepoRoot $RepoRoot -LogDir $stackLogDir -Which tg -Env @{ MOCK_TG_DOCS = ($docsDir -replace '\\', '/') }
    $h = Get-LlmGatewayHealth -Container $Container
    if (-not $h -or -not $h.telegram -or [string]$h.telegram.upstream -ne $MockUrl) {
        throw "Gateway-Telegram-Relay im Verbund zeigt nicht auf $MockUrl - die Installation hat die Test-Weiche nicht gesetzt. Neu bauen: .\scripts\dev\bootstrap_test_stack.ps1 -Reset"
    }
    $MockLog = Resolve-TestMockLogPath -Target $Target -LogFile $MockLog
} else {
    # --- 1) server.js + Dokumente in den Container kopieren -----------------------------------------------
    if (-not (Test-Path $ServerHost)) { throw "Mock-Server nicht gefunden: $ServerHost" }
    $r = Invoke-Native docker @('exec',$Container,'mkdir','-p','/opt/mock_telegram')
    if ($r.Code -ne 0) { throw "mkdir /opt/mock_telegram fehlgeschlagen: $($r.Output -join "`n")" }
    $r = Invoke-Native docker @('cp',$ServerHost,"${Container}:$ServerInC")
    if ($r.Code -ne 0) { throw "docker cp server.js fehlgeschlagen: $($r.Output -join "`n")" }
    if (Test-Path $DocsHost) {
        $r = Invoke-Native docker @('cp',(Join-Path $DocsHost '.'),"${Container}:/opt/mock_telegram/docs")
        if ($r.Code -ne 0) { throw "docker cp docs/ fehlgeschlagen: $($r.Output -join "`n")" }
        # Ueberschreibt die eben kopierten Dateien gleichen Namens.
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "mock_tg_docs_$PID"
        try {
            foreach ($name in (Write-ResolvedDocs $tmpDir)) {
                $r = Invoke-Native docker @('cp',(Join-Path $tmpDir $name),"${Container}:/opt/mock_telegram/docs/$name")
                if ($r.Code -ne 0) { throw "docker cp $name fehlgeschlagen: $($r.Output -join "`n")" }
            }
        } finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
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
}

# Ohne echten Bot (CI free-gates.yml, erfundener Token) lehnt Telegram beim Deploy setWebhook ab: n8n meldet den Workflow
# trotzdem aktiv ("partially published"), seine Route fehlt aber. Darum zaehlt die Route, nicht das Feld active: ohne Secret
# antwortet sie 403, nicht angemeldet 404. Jetzt geht setWebhook an den Mock -> ab- und anmelden. Mit echtem Bot steht sie.
function Get-TelegramRouteStatus([string]$WebhookId) {
    try { return [int](Invoke-WebRequest -Uri "$N8nUrl/webhook/$WebhookId/webhook" -Method Post -UseBasicParsing -ContentType 'application/json' -Body '{}' -TimeoutSec 15).StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }; return -1 }
}
$allWf = (Invoke-RestMethod -Uri "$N8nUrl/api/v1/workflows?limit=250" -Headers $Headers -Method Get).data
foreach ($wf in @($allWf | Where-Object { $_.nodes.type -contains 'n8n-nodes-base.telegramTrigger' })) {
    $hookId = ($wf.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegramTrigger' } | Select-Object -First 1).webhookId
    if ((Get-TelegramRouteStatus $hookId) -ne 404) { continue }
    $api = "$N8nUrl/api/v1/workflows/$($wf.id)"
    try { Invoke-RestMethod -Uri "$api/unpublish" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { Write-Host "  unpublish $($wf.name): $($_.Exception.Message)" }
    # unpublish antwortet, bevor die Abmeldung fertig ist (provisioning/lib/common.sh n8n_delete_workflow) -> kurz wiederholen.
    $st = 404
    for ($i = 0; $i -lt 15 -and $st -eq 404; $i++) {
        try { Invoke-RestMethod -Uri "$api/publish" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { Write-Host "  publish $($wf.name): $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
        $st = Get-TelegramRouteStatus $hookId
    }
    if ($st -eq 404) { throw "Telegram-Route von $($wf.name) blieb nach dem Neu-Anmelden gegen den Mock 404." }
    Write-Host "Telegram-Trigger von $($wf.name) gegen den Mock angemeldet (Route $st)."
}

# --- 4) State-Block schreiben -----------------------------------------------------------------------
$mockBlock = if ($Target.Runtime -eq 'compose') { [ordered]@{ port = [int]$MockPort; url = $MockUrl; log = $MockLog; container = $mockC; cred_id = $credId } }
             else { [ordered]@{ port = [int]$MockPort; url = $MockUrl; log = $MockLog; unit = $Unit; cred_id = $credId } }
Set-TestN8nStateBlock -Name 'mock_telegram' -Block $mockBlock

Write-Host ""
# Der Mock antwortet auf getMe mit diesem Namen; ohne echten Test-Bot bliebe sonst der Platzhalter und Einladungen scheiterten.
[void](Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT core.fn_set_bot_username('mock_test_bot');"))

Write-Host "============================================================"
Write-Host "  Mock-Telegram aktiv"
if ($Target.Runtime -eq 'compose') { Write-Host "  Attrappe:  $mockC  (127.0.0.1:$MockPort im Verbund)" }
else { Write-Host "  Unit:      $Unit  (127.0.0.1:$MockPort, im Container)" }
Write-Host "  Log:       $MockLog  (lesen: Get-MockTelegramRequests)"
Write-Host "  baseUrl:   Credential 'Telegram account' -> $MockUrl"
Write-Host ""
Write-Host "  HITL-Gate deterministisch pruefen:  .\scripts\dev\hitl_gate_test.ps1"
Write-Host "  deaktivieren:                       .\scripts\dev\enable_mock_telegram.ps1 -Down"
Write-Host "============================================================"
