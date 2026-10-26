#Requires -Version 5.1
# test_n8n_state.ps1 — gemeinsamer Verbindungs-Resolver fuer die n8n-Integrations-Tiers.
#
# Die ephemere Test-n8n-Instanz (scripts/dev/bootstrap_test_n8n.ps1) schreibt ihre Verbindungsdaten
# (URL der socat-Bruecke + frisch geminteter N8N_API_KEY) nach .local/n8ntest_state.<container>.json. Die Tier-
# Skripte (infra_test/n8n_test/orch_test/e2e_test/multiturn_test) lesen sie hierueber, statt die
# (abgeschaltete) Prod-Instanz aus .env zu nehmen — strukturell sauber raus aus Prod.
#
# Dot-sourcen + aufrufen:
#   . "$PSScriptRoot\dev\test_n8n_state.ps1"
#   $conn = Get-TestN8nConnection            # @{ Url; ApiKey; Container } oder Throw mit Hinweis
#
# Throw (kein Silent-Fallback): laeuft kein Test-Substrat, soll der Tier-Lauf mit klarer Anweisung
# abbrechen statt versehentlich gegen eine fremde Instanz zu feuern.
# Get-TestN8nStateFile — DIE eine Adresse der Zustandsdatei: je Container eine eigene
# (.local/n8ntest_state.<container>.json; Container = $env:N8NTEST_CONTAINER, sonst der Bootstrap-Default). Vorher teilten
# sich alle Substrate einer Arbeitskopie EINE Datei -> ein zweites Substrat ueberschrieb URL/API-Key des ersten (2026-10-26:
# 403 in cron_text waehrend einer parallelen Update-Probe). Jeder Leser/Schreiber (Bootstrap, enable_mock_*, Tier-Skripte)
# holt den Pfad hier.
function Get-TestN8nStateFile {
    param([string]$Container = $(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' }))
    $repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
    return (Join-Path $repoRoot ".local\n8ntest_state.$Container.json")
}

# Get-TestN8nState — der rohe Zustand (url, api_key, container, mock_*) des aktuellen Substrats; Throw mit Hinweis, wenn keins.
function Get-TestN8nState {
    $f = Get-TestN8nStateFile
    if (-not (Test-Path $f)) {
        throw "Kein Test-Substrat fuer Container '$(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' })' ($f fehlt). Zuerst hochfahren: .\scripts\dev\bootstrap_test_n8n.ps1"
    }
    return ([System.IO.File]::ReadAllText($f, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
}

function Get-TestN8nConnection {
    param([switch]$AllowMissing)
    $stateFile = Get-TestN8nStateFile
    if (-not (Test-Path $stateFile)) {
        if ($AllowMissing) { return $null }
        throw "Kein Test-Substrat gefunden ($stateFile fehlt). Zuerst hochfahren: .\scripts\dev\bootstrap_test_n8n.ps1"
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        $s = [System.IO.File]::ReadAllText($stateFile, $utf8) | ConvertFrom-Json
    } catch {
        throw "Test-Substrat-State unlesbar ($stateFile): $_. Neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset"
    }
    if ([string]::IsNullOrWhiteSpace($s.url)) {
        throw "Test-Substrat-State ohne 'url' ($stateFile). Neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset"
    }
    if ([string]::IsNullOrWhiteSpace($s.container)) {
        # ohne Container-Name kann der DB-Zugriff (docker exec) nicht binden -> klar abbrechen statt
        # spaeter ein kryptisches `docker exec "" ...` zu werfen.
        throw "Test-Substrat-State ohne 'container' ($stateFile). Neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset"
    }
    return [pscustomobject]@{
        Url       = $s.url.TrimEnd('/')
        ApiKey    = [string]$s.api_key
        Container = [string]$s.container
    }
}

# --- Container-DB-Zugriff (Tier 2 Fixture-Seed/-Pre-Flight + Tier 5 verify/cleanup) ---------
# Die n8n-Test-Instanz haelt ihr Postgres NUR container-intern (127.0.0.1:5432, von install.sh als
# DB 'n8n' angelegt) — Docker-Port-Publishing erreicht den loopback-gebundenen Dienst nicht, und es
# gibt keinen TCP-Passwort-Pfad. Die DB-beruehrenden Tiers erreichen die DB daher ueber
#   docker exec <container> runuser -u postgres -- psql -d n8n
# = Peer-Auth am Socket, KEIN Passwort, KEIN zusaetzlicher Port, EXAKT der Pfad, mit dem
# apply_schema.sh das Schema baute (kein Drift). Superuser-Zugriff; fn-Calls (fn_clear_e2e_data)
# laufen damit nicht ueber die Laufzeit-Schreibrolle, was fuer Cleanup/Verify unerheblich ist.
$script:TestN8nDbName = 'n8n'

# Invoke-TestN8nPsql — psql IM Container gegen die n8n-DB. $PsqlArgs sind die Argumente NACH dem
# festen Praefix (z. B. @('-t','-A','-c',$sql)). EAP lokal auf 'Continue' (PS-5.1: native stderr
# unter 'Stop' + 2>&1 wuerde als terminierender NativeCommandError werfen). Rueckgabe @{ Code; Output }.
function Invoke-TestN8nPsql {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string[]]$PsqlArgs,
        [string]$Database = $script:TestN8nDbName
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $dockerArgs = @('exec', $Container, 'runuser', '-u', 'postgres', '--',
                    'psql', '--no-psqlrc', '-X', '-v', 'ON_ERROR_STOP=1', '-d', $Database) + $PsqlArgs
    $out = & docker @dockerArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

# Clear-HitlPending — Karte-offen-Sperre (agent.hitl_pending) im Substrat leeren. Ein per Stop-Exec beendeter
# Gate-Lauf erreicht nie 'Close pending' -> seine Zeile sperrte den Owner-Chat bis zur TTL (16 Min) und jeder
# Folgefall liefe in 'Reply card open'. Aufrufer: Initialize-AgentTestState, hitl_gate_test, real_ingress_test.
# Tabelle fehlt (altes Substrat) -> to_regclass-Guard, kein Fehler.
function Clear-HitlPending {
    param([Parameter(Mandatory)][string]$Container)
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc',
        "DO `$`$ BEGIN IF to_regclass('agent.hitl_pending') IS NOT NULL THEN DELETE FROM agent.hitl_pending; END IF; END `$`$;")
    if ($res.Code -ne 0) { throw "Clear-HitlPending fehlgeschlagen: $($res.Output -join "`n")" }
}

# Clear-ThinkingLease — "Bot denkt nach"-Schalter (agent.thinking_lease) im Substrat leeren. Ein per Stop-Exec beendeter
# Orchestrator-Lauf loescht seinen Schalter nie -> seine Draft-Schleife (core.sub_show_thinking) schriebe bis zur TTL
# sendMessageDraft ins Telegram-Mock-Log und verschmutzte Folgefaelle. Ohne Schalter endet sie beim naechsten Claim.
# Aufrufer: neben jedem Clear-HitlPending. Tabelle fehlt (altes Substrat) -> to_regclass-Guard, kein Fehler.
function Clear-ThinkingLease {
    param([Parameter(Mandatory)][string]$Container)
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc',
        "DO `$`$ BEGIN IF to_regclass('agent.thinking_lease') IS NOT NULL THEN DELETE FROM agent.thinking_lease; END IF; END `$`$;")
    if ($res.Code -ne 0) { throw "Clear-ThinkingLease fehlgeschlagen: $($res.Output -join "`n")" }
}

# --- Test-Identitaets-Riegel (WS-5b) ----------------------------------------------------------
# Die LLM-SCHREIB-Suiten (finance/advisor n8n_test + e2e) referenzieren den FIKTIVEN Golden-Owner
# 'Erika' (nie echte PII). Der Substrat-Owner wird aber aus .env TEST_OWNER_* gebootstrappt -> traegt
# dort jemand einen anderen/ECHTEN Namen, driften Substrat-Haushalt und Goldens auseinander: der Agent
# verweigert dann JEDEN 'Erika'-Auftrag ('nicht im Haushalt') und eine GANZE LLM-Suite verbrennt nur
# Klaerungs-Fehlschlaege (real getroffen: ein Substrat mit echtem Owner-Namen liess 21/32 e2e-Faelle scheitern).
# Dieser Riegel prueft VOR dem ersten LLM-Call (1 gratis DB-Query) den Haushalts-Owner -> sonst HARTER
# Abbruch mit Fix-Hinweis (kein Credit-Spend). Faengt zugleich versehentliche ECHTE-DATEN-Lecks
# (Owner-Vorgabe: NIE reale PII in Test-Faellen). Aufrufer: n8n_test (finance/advisor) + e2e_test.
function Assert-GoldenHousehold {
    param([Parameter(Mandatory)][string]$Container)
    $sql = "SELECT count(*) FROM agent.core_contexts c, " +
           "jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) p " +
           "WHERE c.name='family' AND p->>'role'='owner' AND p->>'first_name'='Erika';"
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', $sql)
    $cnt = if ($res.Code -eq 0) { ($res.Output -join '').Trim() } else { 'DB-Fehler' }
    if ($cnt -ne '1') {
        throw ("Test-Identitaets-Riegel: der Substrat-Haushalt hat NICHT den fiktiven Golden-Owner 'Erika' " +
               "(gefunden: count=$cnt). Ursache i.d.R.: .env TEST_OWNER_FIRST_NAME/_LAST_NAME/_BIRTH_DATE traegt " +
               "einen anderen (evtl. ECHTEN) Namen -> der Bootstrap legt einen abweichenden Owner an, die Goldens " +
               "nutzen aber 'Erika Mustermann' -> jeder Account-Fall scheitert ('Erika nicht im Haushalt') und die " +
               "LLM-Suite verbrennt nur Klaerungs-Fehlschlaege. FIX: in .env TEST_OWNER_FIRST_NAME=Erika / " +
               "_LAST_NAME=Mustermann / _BIRTH_DATE=1980-05-20 setzen (KEINE echten Daten!), dann " +
               ".\scripts\dev\bootstrap_test_n8n.ps1 -Reset. Abbruch VOR dem ersten LLM-Call (kein Credit-Spend).")
    }
    Write-Host "Test-Identitaets-Riegel: Haushalts-Owner = fiktive 'Erika' (kein PII-Leak, Goldens ausgerichtet)." -ForegroundColor DarkGreen
}

# --- Mock-Telegram-Server (Teststrategie Phase 5) -------------------------------------------
# Der Mock (tests/mock_telegram/server.js) laeuft IM Container und zeichnet jeden ausgehenden
# Bot-API-Call als JSON-Zeile in eine Logdatei. Diese Helfer lesen/leeren die Aufzeichnung ueber
# `docker exec` (analog Invoke-TestN8nPsql) und loesen das HITL-Gate ueber die abgefangene,
# signierte Resume-URL aus. Aktiviert wird der Mock mit scripts/dev/enable_mock_telegram.ps1.
$script:MockTelegramLog = '/tmp/mock_telegram.jsonl'

# Get-MockTelegramRequests — alle aufgezeichneten Calls als Objekte (aelteste zuerst). Leer = @().
function Get-MockTelegramRequests {
    param(
        [Parameter(Mandatory)][string]$Container,
        [string]$LogFile = $script:MockTelegramLog
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker exec $Container sh -c "cat '$LogFile' 2>/dev/null" 2>$null
    $ErrorActionPreference = $prev
    $reqs = @()
    foreach ($line in @($out)) {
        $s = [string]$line
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        try { $reqs += ($s | ConvertFrom-Json) } catch { }
    }
    return $reqs
}

# Clear-MockTelegramRequests — Logdatei truncaten (Test-Isolation vor dem naechsten Fall).
function Clear-MockTelegramRequests {
    param(
        [Parameter(Mandatory)][string]$Container,
        [string]$LogFile = $script:MockTelegramLog
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker exec $Container sh -c ": > '$LogFile'" 2>$null | Out-Null
    $ErrorActionPreference = $prev
}

# Get-HitlResumeUrl — aus einer abgefangenen sendMessage-Aufzeichnung die signierte Resume-URL des
# gewuenschten Zweigs (Approve/Decline) ziehen und Schema+Host auf die erreichbare Bruecke umschreiben.
# Die Signatur deckt NUR pathname+search (n8n prepareUrlForSigning) -> Host-Rewrite ist signatur-sicher.
# Identifikation ueber den `approved`-Query-Param der Button-URL (nicht ueber das Label).
function Get-HitlResumeUrl {
    param(
        [Parameter(Mandatory)][object]$Request,     # eine Aufzeichnung aus Get-MockTelegramRequests (method=sendMessage)
        [Parameter(Mandatory)][bool]$Approved,
        [Parameter(Mandatory)][string]$BridgeUrl     # z. B. http://127.0.0.1:5680 (socat-Bruecke -> n8n)
    )
    $want = if ($Approved) { 'true' } else { 'false' }
    $kb = $null
    try { $kb = $Request.body.reply_markup.inline_keyboard } catch { }
    if (-not $kb) { throw "Aufzeichnung hat kein reply_markup.inline_keyboard (kein HITL-Gate-Send?)." }
    $base = [uri]$BridgeUrl
    foreach ($row in $kb) {
        foreach ($btn in $row) {
            # Bestaetigen im Chat (chatApproval): callback_data 'nhitl1|<execId>|a|d|<hmac>' statt Link. Rueckgabe als
            # Pseudo-URL auf den n8n-Endpunkt /webhook-waiting-telegram; Invoke-HitlResume baut daraus das Telegram-
            # callback_query-Update (wie der Orchestrator-Trigger es weiterreicht).
            $cb = [string]$btn.callback_data
            if ($cb -match '^nhitl1\|[^|]+\|([ad])\|') {
                if (($Matches[1] -eq 'a') -eq $Approved) {
                    return ('{0}://{1}/webhook-waiting-telegram?cb={2}&chat={3}&msg={4}' -f $base.Scheme, $base.Authority,
                        [uri]::EscapeDataString($cb), [uri]::EscapeDataString([string]$Request.body.chat_id), [string]$Request.result_message_id)
                }
                continue
            }
            if (-not $btn.url) { continue }
            $u = [uri]$btn.url
            # `approved`-Query-Param ohne System.Web parsen (PS-5.1-Assembly-Load vermeiden).
            $approvedVal = $null
            foreach ($pair in ($u.Query.TrimStart('?') -split '&')) {
                $kv = $pair -split '=', 2
                if ($kv[0] -eq 'approved') { $approvedVal = $kv[1] }
            }
            if ($approvedVal -eq $want) {
                # Schema+Host -> Bruecke; PathAndQuery (inkl. Signatur) unveraendert uebernehmen.
                return ('{0}://{1}{2}' -f $base.Scheme, $base.Authority, $u.PathAndQuery)
            }
        }
    }
    throw "Keine Button-URL mit approved=$want gefunden."
}

# Get-HitlExecId — Gate-Execution-id aus einer Get-HitlResumeUrl-Rueckgabe (Link: /webhook-waiting/<id>/…; Chat:
# callback_data nhitl1|<id>|…). 0 = nicht erkennbar.
function Get-HitlExecId {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match '/webhook-waiting/([0-9]+)/') { return [int]$Matches[1] }
    if ($Url -match '[?&]cb=([^&]+)') { $cb = [uri]::UnescapeDataString($Matches[1]); if ($cb -match '^nhitl1\|([0-9]+)\|') { return [int]$Matches[1] } }
    return 0
}

# Get-HitlTelegramSecret — der Secret-Header, den der Orchestrator-Trigger beim Weiterreichen eines Tipps setzt
# (n8n Telegram hitl/tokens.js deriveHitlSecretToken): HMAC-SHA256(Schluessel = hmacSignatureSecret der Instanz,
# 'n8n-telegram-hitl-secret:<Bot-Token>') als base64url, 43 Zeichen. hmacSignatureSecret = sha256hex('hmac-signature:'
# + N8N_ENCRYPTION_KEY) (n8n-core InstanceSettings, ohne N8N_HMAC_SIGNATURE_SECRET). Bot-Token = die Telegram-
# Credential des Substrats (TEST_TELEGRAM_BOT_TOKEN). Je Container gecacht.
$script:HitlSecretCache = @{}
function Get-HitlTelegramSecret {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$BotToken)
    if ($script:HitlSecretCache[$Container]) { return $script:HitlSecretCache[$Container] }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $enc = (& docker exec $Container sh -c "grep -E '^N8N_ENCRYPTION_KEY=' /etc/n8n/n8n.env | tail -n1 | cut -d= -f2-" 2>$null | Select-Object -First 1)
    $ErrorActionPreference = $prev
    $enc = ([string]$enc).Trim().Trim("'").Trim('"')
    if (-not $enc) { throw "N8N_ENCRYPTION_KEY im Container $Container nicht lesbar." }
    $utf8 = [System.Text.Encoding]::UTF8
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hmacSecret = -join ($sha.ComputeHash($utf8.GetBytes("hmac-signature:$enc")) | ForEach-Object { $_.ToString('x2') })
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,$utf8.GetBytes($hmacSecret))
    $b64 = [Convert]::ToBase64String($h.ComputeHash($utf8.GetBytes("n8n-telegram-hitl-secret:$BotToken")))
    $tok = $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    if ($tok.Length -gt 43) { $tok = $tok.Substring(0, 43) }
    $script:HitlSecretCache[$Container] = $tok
    return $tok
}

# Invoke-HitlResume — Link-Knopf: die (umgeschriebene) Resume-URL als GET feuern (= Browser-GET). Chat-Knopf
# (Pseudo-URL /webhook-waiting-telegram?cb=…): das callback_query-Update so POSTen, wie der Orchestrator-Trigger es
# weiterreicht (Secret-Header aus Get-HitlTelegramSecret). -FromId = wer tippt (Default: der Chat = privater Chat).
function Invoke-HitlResume {
    param([Parameter(Mandatory)][string]$Url, [string]$FromId, [string]$Container, [string]$BotToken, [string]$Secret)
    if ($Url -notmatch '/webhook-waiting-telegram\?') {
        return Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec 20
    }
    $q = @{}
    foreach ($pair in (([uri]$Url).Query.TrimStart('?') -split '&')) { $kv = $pair -split '=', 2; $q[$kv[0]] = [uri]::UnescapeDataString($kv[1]) }
    if (-not $Secret) {
        if (-not $Container) { $Container = (Get-TestN8nConnection).Container }
        if (-not $BotToken)  { $BotToken = $script:TEST_TELEGRAM_BOT_TOKEN }
        if (-not $BotToken) {   # Aufrufer ohne .env-Import (real_ingress_test, Wait-ExecResolvingGates): selbst lesen
            $envFile = Join-Path (git -C $PSScriptRoot rev-parse --show-toplevel) '.env'
            if (Test-Path $envFile) {
                $line = [System.IO.File]::ReadAllLines($envFile) | Where-Object { $_ -match '^\s*TEST_TELEGRAM_BOT_TOKEN=' } | Select-Object -Last 1
                if ($line) { $BotToken = ($line -split '=', 2)[1].Trim().Trim("'").Trim('"') }
            }
        }
        if (-not $BotToken)  { throw "Invoke-HitlResume (Chat-Knopf): Bot-Token unbekannt (TEST_TELEGRAM_BOT_TOKEN aus .env oder -BotToken)." }
        $Secret = Get-HitlTelegramSecret -Container $Container -BotToken $BotToken
    }
    if (-not $FromId) { $FromId = $q['chat'] }
    $msgId = 0; [void][int]::TryParse([string]$q['msg'], [ref]$msgId)
    $update = [ordered]@{
        update_id = Get-Random -Minimum 100000 -Maximum 999999999
        callback_query = [ordered]@{
            id   = [string](Get-Random -Minimum 100000 -Maximum 999999999)
            from = [ordered]@{ id = [long]$FromId; is_bot = $false; first_name = 'Test' }
            message = [ordered]@{ message_id = $msgId; chat = [ordered]@{ id = [long]$q['chat']; type = 'private' }; text = 'HITL probe' }
            chat_instance = '1'
            data = $q['cb']
        }
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($update | ConvertTo-Json -Depth 6 -Compress))
    $target = ('{0}://{1}/webhook-waiting-telegram' -f ([uri]$Url).Scheme, ([uri]$Url).Authority)
    return Invoke-WebRequest -Uri $target -Method Post -UseBasicParsing -TimeoutSec 20 -Body $body `
        -ContentType 'application/json; charset=utf-8' -Headers @{ 'x-telegram-bot-api-secret-token' = $Secret }
}

# --- Mock-LLM-Server (Teststrategie Phase 6) -----------------------------------------------
# Der Mock (tests/mock_llm/server.js) laeuft IM Container und beantwortet Anthropic-/v1/messages-Calls
# gescriptet (tool_use/Text) -> deterministisches, GRATIS Routing/Tool-Path-Testen; jeder andere Pfad -> 404.
# Aktiviert mit scripts/dev/enable_mock_llm.ps1 (biegt den UPSTREAM des LLM-Gateways — die Anthropic-Credential
# zeigt fest auf den Gateway — und optional den googlePalmApi-`host` der Transkription auf den Stub um). Jede
# Entscheidung wird als JSON-Zeile geloggt (offered/task/decision/markers) —
# das ist zugleich der Discovery-Kanal fuer die exakten (sanitisierten) Tool-Function-Namen.
$script:MockLlmLog = '/tmp/mock_llm.jsonl'

# Get-MockLlmRequests — alle aufgezeichneten Entscheidungen als Objekte (aelteste zuerst). Leer = @().
function Get-MockLlmRequests {
    param(
        [Parameter(Mandatory)][string]$Container,
        [string]$LogFile = $script:MockLlmLog
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker exec $Container sh -c "cat '$LogFile' 2>/dev/null" 2>$null
    $ErrorActionPreference = $prev
    $reqs = @()
    foreach ($line in @($out)) {
        $s = [string]$line
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        try { $reqs += ($s | ConvertFrom-Json) } catch { }
    }
    return $reqs
}

# Clear-MockLlmRequests — Logdatei truncaten (Test-Isolation vor dem naechsten Fall).
function Clear-MockLlmRequests {
    param(
        [Parameter(Mandatory)][string]$Container,
        [string]$LogFile = $script:MockLlmLog
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker exec $Container sh -c ": > '$LogFile'" 2>$null | Out-Null
    $ErrorActionPreference = $prev
}

# --- LLM-Gateway (provisioning/llm_gateway): Upstream-Waechter + Kosten-Report ---------------------
# ALLE Claude-Aufrufe des Substrats laufen ueber den Gateway im Container (127.0.0.1:8090). Er schreibt je
# Anfrage eine JSON-Zeile {"ev":"usage",...} (nur Token-Zahlen) ins systemd-Journal seiner Unit. Die Suiten
# merken sich am Start den Journal-CURSOR (nicht die Uhrzeit — die Docker-VM-Uhr kann von Windows abweichen)
# und lesen am Ende nur die neuen Zeilen -> Kostenuebersicht je Lauf.
$script:LlmGatewayUnit = 'lifeagents-llm-gateway'
$script:LlmGatewayHealthUrl = 'http://127.0.0.1:8090/__health'
$script:LlmCostLog = '.local\llm_cost_log.jsonl'

# Get-LlmGatewayHealth — /__health des Gateways im Container ({ok, upstream, static_ttl}) oder $null.
function Get-LlmGatewayHealth {
    param([Parameter(Mandatory)][string]$Container)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker exec $Container curl -fsS --max-time 3 $script:LlmGatewayHealthUrl 2>$null
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    try { return (($out -join '') | ConvertFrom-Json) } catch { return $null }
}

# Assert-LlmGatewayUpstream — Schutz vor stillen Kosten bzw. Fake-Paessen: die kostenpflichtigen Suiten verlangen
# 'real' (sonst antworteten gescriptete Mocks), die Gratis-Tiers 'mock' (sonst kostete der Lauf echte Credits).
function Assert-LlmGatewayUpstream {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][ValidateSet('mock', 'real')][string]$Expect)
    $h = Get-LlmGatewayHealth -Container $Container
    if (-not $h) { throw "LLM-Gateway antwortet im Container nicht ($script:LlmGatewayHealthUrl) — Substrat neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset" }
    $isMock = ([string]$h.upstream) -like 'http://127.0.0.1*'
    if ($Expect -eq 'real' -and $isMock) { throw "LLM-Gateway zeigt auf den Mock ($($h.upstream)) — die Suite bekaeme gescriptete Antworten statt echter. Erst: .\scripts\dev\enable_mock_llm.ps1 -Down" }
    if ($Expect -eq 'mock' -and -not $isMock) { throw "LLM-Gateway zeigt auf die ECHTE API ($($h.upstream)) — der Gratis-Tier wuerde Credits kosten. Erst: .\scripts\dev\enable_mock_llm.ps1" }
}

# Get-LlmUsageCursor — aktueller Journal-Cursor der Gateway-Unit (Start-Marke eines Laufs) oder $null.
function Get-LlmUsageCursor {
    param([Parameter(Mandatory)][string]$Container)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker exec $Container journalctl -u $script:LlmGatewayUnit -n 1 --show-cursor -o cat --no-pager 2>$null
    $ErrorActionPreference = $prev
    foreach ($line in @($out)) { if ([string]$line -match '^-- cursor: (.+)$') { return $Matches[1].Trim() } }
    return $null
}

# Get-LlmUsage — die usage-Zeilen NACH dem Cursor (ohne Cursor: alle) als Objekte, aelteste zuerst.
function Get-LlmUsage {
    param([Parameter(Mandatory)][string]$Container, [string]$AfterCursor)
    $jArgs = @('exec', $Container, 'journalctl', '-u', $script:LlmGatewayUnit, '-o', 'cat', '--no-pager')
    if ($AfterCursor) { $jArgs += "--after-cursor=$AfterCursor" }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker @jArgs 2>$null
    $ErrorActionPreference = $prev
    $rows = @()
    foreach ($line in @($out)) {
        $s = [string]$line
        if ($s -notmatch '"ev":"usage"') { continue }
        try { $rows += ($s | ConvertFrom-Json) } catch { }
    }
    return $rows
}

# Get-LlmPriceTable — n8n_model_id -> pricing_usd_per_mtok aus dem Modell-Register (SSOT packages/core/seed/ai_models.json).
function Get-LlmPriceTable {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $reg = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\seed\ai_models.json'), $utf8) | ConvertFrom-Json
    $t = @{}
    foreach ($m in @($reg)) { if ($m.pricing_usd_per_mtok) { $t[[string]$m.n8n_model_id] = $m.pricing_usd_per_mtok } }
    return $t
}

# Get-LlmRequestCost — @{ Cost; NoCache } einer usage-Zeile in USD oder $null (Modell ohne Preis -> "nicht bepreist").
# input_tokens = UNGECACHTER Rest (Anthropic-Semantik); Gesamt-Eingabe = input + cache_creation + cache_read.
# "Ohne Caching" = die ganze Eingabe zum Grundpreis. Langkontext-Stufe (Haiku > 100k) je Anfrage nach Gesamt-Eingabe.
function Get-LlmRequestCost {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][hashtable]$Prices)
    $p = $Prices[[string]$Row.model]
    if (-not $p) { return $null }
    $in = [double]$Row.input_tokens; $cw = [double]$Row.cache_creation_input_tokens; $cr = [double]$Row.cache_read_input_tokens
    $out = [double]$Row.output_tokens
    $w1h = [double]$Row.ephemeral_1h_input_tokens; $w5m = [Math]::Max(0, $cw - $w1h)   # fehlt die Aufteilung -> 5m-Preis
    # Websuche je Anfrage (web_search_usd_per_request im Modell-Register, gleiche Quelle wie core.fn_get_llm_cost_report).
    $web = [double]$Row.web_search_requests * [double]$p.web_search_usd_per_request
    if ($p.long_context -and ($in + $cw + $cr) -gt [double]$p.long_context.above_input_tokens) { $p = $p.long_context }
    $cost = ($in * $p.input + $w5m * $p.cache_write_5m + $w1h * $p.cache_write_1h + $cr * $p.cache_read + $out * $p.output) / 1e6 + $web
    $noCache = (($in + $cw + $cr) * $p.input + $out * $p.output) / 1e6 + $web
    return [pscustomobject]@{ Cost = $cost; NoCache = $noCache }
}

# Write-LlmCostReport — Kostenuebersicht eines Laufs (je Modell + Summe) + eine Verlaufszeile in .local/llm_cost_log.jsonl.
function Write-LlmCostReport {
    param([AllowEmptyCollection()][object[]]$Usage = @(), [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$RepoRoot)
    $rows = @($Usage | Where-Object { $_ })
    Write-Host ''
    Write-Host "Kostenuebersicht ($Label) — Claude-Nutzung dieses Laufs" -ForegroundColor Cyan
    if ($rows.Count -eq 0) { Write-Host '  (keine Claude-Aufrufe aufgezeichnet)' -ForegroundColor DarkGray; return }
    $prices = Get-LlmPriceTable -RepoRoot $RepoRoot
    $tot = [ordered]@{ req = 0; cost = 0.0; nocache = 0.0; tin = 0.0; tread = 0.0; fallback = 0; unpriced = 0 }
    foreach ($g in ($rows | Group-Object { [string]$_.model })) {
        $a = [ordered]@{ req = 0; in = 0.0; cw = 0.0; cr = 0.0; out = 0.0; web = 0.0; cost = 0.0; nocache = 0.0; unpriced = 0 }
        foreach ($r in $g.Group) {
            $a.req++; $a.in += [double]$r.input_tokens; $a.cw += [double]$r.cache_creation_input_tokens
            $a.cr += [double]$r.cache_read_input_tokens; $a.out += [double]$r.output_tokens; $a.web += [double]$r.web_search_requests
            if ($r.fallback -eq $true) { $tot.fallback++ }
            $c = Get-LlmRequestCost -Row $r -Prices $prices
            if ($c) { $a.cost += $c.Cost; $a.nocache += $c.NoCache } else { $a.unpriced++ }
        }
        $name = if ($g.Name) { $g.Name } else { '(unbekannt)' }
        $priced = if ($a.unpriced -gt 0) { " — $($a.unpriced) nicht bepreist (Modell fehlt in ai_models.json)" } else { '' }
        Write-Host ("  {0,-20} {1,4} Anfr. | Eingabe {2,9:N0} | Cache schreiben {3,9:N0} | Cache lesen {4,9:N0} | Ausgabe {5,8:N0} | Websuchen {6,3} | {7,7:N3} $ (ohne Cache {8,7:N3} $){9}" -f `
            $name, $a.req, $a.in, $a.cw, $a.cr, $a.out, $a.web, $a.cost, $a.nocache, $priced)
        $tot.req += $a.req; $tot.cost += $a.cost; $tot.nocache += $a.nocache; $tot.unpriced += $a.unpriced
        $tot.tin += $a.in + $a.cw + $a.cr; $tot.tread += $a.cr
    }
    $save = if ($tot.nocache -gt 0) { 100 * (1 - $tot.cost / $tot.nocache) } else { 0 }
    $hit = if ($tot.tin -gt 0) { 100 * $tot.tread / $tot.tin } else { 0 }
    $first = $rows[0]
    Write-Host ("  SUMME {0} Anfragen: {1:N3} $ — ohne Caching {2:N3} $ -> Ersparnis {3:N1} % | Cache-Trefferquote (Eingabe) {4:N1} %" -f `
        $tot.req, $tot.cost, $tot.nocache, $save, $hit) -ForegroundColor Green
    Write-Host ("  Erste Anfrage des Laufs: Cache gelesen {0:N0} / geschrieben {1:N0} Token ({2})" -f `
        [double]$first.cache_read_input_tokens, [double]$first.cache_creation_input_tokens, $first.model) -ForegroundColor DarkGray
    if ($tot.fallback -gt 0) { Write-Host "  WARNUNG: $($tot.fallback) Anfrage(n) liefen OHNE Caching (Anthropic lehnte die Haltepunkte ab) — journalctl -u $script:LlmGatewayUnit" -ForegroundColor Yellow }
    if ($tot.unpriced -gt 0) { Write-Host "  HINWEIS: $($tot.unpriced) Anfrage(n) ohne Preis — Summe unvollstaendig." -ForegroundColor Yellow }
    $line = [ordered]@{ t = (Get-Date).ToUniversalTime().ToString('o'); label = $Label; requests = $tot.req
        cost_usd = [Math]::Round($tot.cost, 4); nocache_usd = [Math]::Round($tot.nocache, 4); savings_pct = [Math]::Round($save, 1)
        hit_pct = [Math]::Round($hit, 1); fallback = $tot.fallback; unpriced = $tot.unpriced }
    try {
        $logPath = Join-Path $RepoRoot $script:LlmCostLog
        [System.IO.Directory]::CreateDirectory((Split-Path $logPath)) | Out-Null
        [System.IO.File]::AppendAllText($logPath, (([pscustomobject]$line | ConvertTo-Json -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Host "  (Verlaufszeile nicht geschrieben: $($_.Exception.Message))" -ForegroundColor DarkGray }
}

# Invoke-TestN8nPsqlFile — eine SQL-Datei vom HOST (Source of Truth) in der Container-DB ausfuehren:
# docker cp -> /tmp (0644, damit der postgres-User sie liest) -> psql -f -> aufraeumen.
function Invoke-TestN8nPsqlFile {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$HostFile,
        [string]$Database = $script:TestN8nDbName,
        [string[]]$PsqlArgs = @()
    )
    if (-not (Test-Path $HostFile)) { throw "SQL-Datei nicht gefunden: $HostFile" }
    $inC = "/tmp/n8ntest_$([System.IO.Path]::GetFileName($HostFile))"
    $code = -1; $out = @()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $cp = & docker cp $HostFile "${Container}:$inC" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "docker cp '$HostFile' fehlgeschlagen: $($cp -join ' ')" }
        & docker exec $Container chmod 0644 $inC 2>&1 | Out-Null
        $execArgs = @('exec', $Container, 'runuser', '-u', 'postgres', '--',
                      'psql', '--no-psqlrc', '-X', '-v', 'ON_ERROR_STOP=1', '-d', $Database) + $PsqlArgs + @('-f', $inC)
        $out  = & docker @execArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        # Temp IMMER raeumen (auch nach throw/Abbruch); rm -f = no-op, falls nie kopiert. EAP danach zurueck.
        & docker exec $Container rm -f $inC 2>&1 | Out-Null
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

# --- Geteilte Real-Path-Test-Mechanik (Teststrategie Phase 8 — Weg C) -----------------------
# Nach dem Teardown der Test-Sonderlocken (kein test_/test_e2e-Gate-Bypass, kein Orchestrator-
# "Test entry") laufen ALLE LLM-Tiers ueber den Prod-Pfad: numerische chat_id + echtes Send-and-Wait-
# Gate, das ueber das abgefangene Mock-Telegram aufgeloest wird. Diese Helfer kapseln die gemeinsame
# Mechanik (Ingress aufloesen, Telegram-Update feuern, Owner pairen, Memory leeren, Execution zum
# Terminalstatus treiben + JEDES Gate ueber die signierte Resume-URL aufloesen). Genutzt von
# real_ingress/orch_test/mock_route_test/n8n_test/e2e_test/multiturn_test — EINE Quelle, kein Drift.

# Hoechste bestehende Execution-id eines Workflows (n8n vergibt GLOBAL monotone Integer-ids). Vor dem
# Feuern aufnehmen -> die eigene Execution ist danach die EINZIGE mit id > diesem Wert (race-frei, kein
# Zeitfenster). Auch der Gate-Floor: jede Gate-Execution dieses Laufs hat id > diesem Wert.
function Get-MaxExecId {
    param([Parameter(Mandatory)][string]$WfId, [Parameter(Mandatory)][string]$BridgeUrl, [Parameter(Mandatory)][string]$ApiKey)
    try {
        $d = (Invoke-RestMethod -Uri "$BridgeUrl/api/v1/executions?workflowId=$WfId&limit=1" -Headers @{ 'X-N8N-API-KEY' = $ApiKey } -Method Get).data
        if ($d -and @($d).Count -gt 0) { return [int]$d[0].id }
    } catch { }
    return 0
}

# Einen Cron SOFORT starten (schnellere freie Gates 2026-10-26): core.cron_run.test_harness ruft den Workflow ueber seinen
# 'Test run'-Einstieg (Build-Workflow) auf, statt den Zeitplan auf jede Minute zu stellen. Der POST kehrt direkt nach dem
# Start zurueck (waitForSubWorkflow=false) -> der Aufrufer wartet selbst auf die neue Execution (Get-MaxExecId vorher).
# Ein Startfehler (kein Einstieg, unbekannte id) kommt als 'error' der Antwort und wirft hier, statt als stiller Timeout.
# Test-TestCronHarness: $true, wenn das Substrat den Eingang hat (aelteres Substrat -> Zeitplan-Weg des Aufrufers).
function Test-TestCronHarness {
    param([Parameter(Mandatory)][string]$BridgeUrl, [Parameter(Mandatory)][string]$ApiKey)
    $wf = (Invoke-RestMethod -Uri "$BridgeUrl/api/v1/workflows?limit=250" -Headers @{ 'X-N8N-API-KEY' = $ApiKey } -Method Get).data
    return $null -ne ($wf | Where-Object { $_.name -eq 'core.cron_run.test_harness' -and $_.active })
}
function Start-TestCron {
    param([Parameter(Mandatory)][string]$BridgeUrl, [Parameter(Mandatory)][string]$Secret, [Parameter(Mandatory)][string]$WorkflowId,
          [int]$TimeoutSec = 60)
    $r = Invoke-RestMethod -Uri "$BridgeUrl/webhook/cron-run-test" -Method Post -Headers @{ 'X-Test-Auth' = $Secret } `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec `
        -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ workflow_id = $WorkflowId } | ConvertTo-Json)))
    if ($r.error) { throw "Cron $WorkflowId nicht gestartet: $(($r.error | ConvertTo-Json -Depth 4 -Compress))" }
    return $r
}

# Deterministische, numerische Test-chat_id je Case (Memory-Isolation ohne test_-Prefix). Stabiler
# FNV-1a-Hash des Case-id-Seeds -> 9-stellige positive Zahl (Bereich ~900000000..999999999); kollidiert
# praktisch nicht mit dem gepairten Owner-uid und wird vor jedem Case ohnehin frisch geleert.
function Get-TestChatId {
    param([Parameter(Mandatory)][string]$Seed)
    [long]$h = 0
    foreach ($c in $Seed.ToCharArray()) { $h = ($h * 131 + [long][char]$c) % 1000000000 }
    return [long](900000000 + ($h % 90000000))
}

# Den ECHTEN Telegram-Trigger-Webhook des Orchestrators aufloesen (Produktiv-Eingang, kein Harness).
# Liefert @{ Url; Secret; OrchWfId }. n8n registriert die Produktiv-URL als {webhookId}/webhook; der
# Telegram-Trigger validiert Header X-Telegram-Bot-Api-Secret-Token == {workflowId}_{nodeId}
# (non-[A-Za-z0-9_-] gestrippt, GenericFunctions.getSecretToken) — ohne 403.
function Resolve-OrchestratorIngress {
    param([Parameter(Mandatory)][string]$BridgeUrl, [Parameter(Mandatory)][string]$ApiKey)
    $headers = @{ 'X-N8N-API-KEY' = $ApiKey }
    $wfList = Invoke-RestMethod -Uri "$BridgeUrl/api/v1/workflows?limit=200" -Headers $headers -Method Get
    $orchWf = $wfList.data | Where-Object { $_.name -eq 'agent.orchestrator.main_route' } | Select-Object -First 1
    if (-not $orchWf) { throw "Workflow 'agent.orchestrator.main_route' nicht gefunden (Substrat deployt?)." }
    $orchDetail = Invoke-RestMethod -Uri "$BridgeUrl/api/v1/workflows/$($orchWf.id)" -Headers $headers -Method Get
    $tg = $orchDetail.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegramTrigger' } | Select-Object -First 1
    if (-not $tg -or -not $tg.webhookId) { throw "Telegram-Trigger-Node (mit webhookId) im Orchestrator nicht gefunden." }
    return [pscustomobject]@{
        Url      = "$BridgeUrl/webhook/$($tg.webhookId)/webhook"
        Secret   = (("{0}_{1}" -f $orchWf.id, $tg.id) -replace '[^a-zA-Z0-9_\-]+', '')
        OrchWfId = $orchWf.id
    }
}

# Eindeutige Test-update_id: update_id ist der Dedupe-Schluessel der Eingangs-Buendelung (agent.ingress_buffer, PK,
# 2 min) -> eine zufaellige Wiederholung liefe still als Duplikat (drop). Millisekunden-Zeit x 100 + Zufall
# kollidiert praktisch nie und bleibt unter 2^53 (JSON-/JS-sicher).
function New-TestUpdateId {
    return [long]([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 100 + (Get-Random -Minimum 0 -Maximum 100))
}

# Eine TELEGRAM-foermige Update an den echten Webhook POSTen (numerische chat_id + from_uid). Client-
# Timeout ist KEIN Fehler (Execution laeuft serverseitig weiter). Liefert die Fire-Zeit (UTC).
function Send-TelegramIngress {
    param(
        [Parameter(Mandatory)][string]$IngressUrl, [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$FromUid, [Parameter(Mandatory)][string]$Text
    )
    $update = @{
        update_id = New-TestUpdateId
        message   = @{
            message_id = [int](Get-Random -Minimum 1000 -Maximum 99999)
            date       = [long][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            from       = @{ id = $FromUid; is_bot = $false; first_name = 'IngressTest' }
            chat       = @{ id = $ChatId; type = 'private' }
            text       = $Text
        }
    }
    $body = $update | ConvertTo-Json -Depth 6 -Compress
    $fire = (Get-Date).ToUniversalTime()
    try {
        Invoke-RestMethod -Uri $IngressUrl -Method Post -TimeoutSec 8 `
            -Headers @{ 'X-Telegram-Bot-Api-Secret-Token' = $Secret } `
            -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) { throw }
    }
    return $fire
}

# Die gepairte Telegram-uid des Fixture-Owners — EINE Adresse fuer alle Treiber-Skripte (entsteht erst zur Laufzeit
# durchs Pairing unten, ist also keine geseedete Fixture-Entitaet in tests/fixtures/fixtures.json). Die Case-Daten
# in tests/agent/core/real_ingress_cases.json tragen denselben Wert als chat_id/from_uid — bei Aenderung mitziehen.
$script:TestOwnerTelegramUid = 880055071

# Owner deterministisch pairen: telegram_user_id = $Uid in die family-Facts. Ohne gepairten Sender
# laeuft der numerische Pfad in den Knock/Pairing-Zweig (fn_resolve_sender found=false). Idempotent.
function Set-OwnerTelegramPairing {
    param([Parameter(Mandatory)][string]$Container, [long]$Uid = $script:TestOwnerTelegramUid)
    $sql = @"
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(CASE WHEN p->>'person_id' = 'owner'
     THEN p || jsonb_build_object('telegram_user_id', ${Uid}::bigint)
     ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $sql)
    if ($r.Code -ne 0) { throw "Owner-Pairing (Container-DB) fehlgeschlagen: $($r.Output -join "`n")" }
}

# Bot-Persona einer Person in den family-Facts setzen ('' oder 'neutral' = Key entfernen, wie fn_set_context_facts) bzw.
# zuruecklesen ('' = Key fehlt). Konsumenten: real_ingress_test (persona_person/-before/expect_persona) und orch_test
# (Case-Feld persona, Owner). Der Code wird nicht geprueft — der Validator der Container-DB lehnt Unbekanntes ab.
function Set-TestPersonaFact {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$PersonId, [string]$Code = '')
    if ("$PersonId$Code" -match "'") { throw "Set-TestPersonaFact: kein Hochkomma in PersonId/Code." }
    $val = if ($Code -and $Code -ne 'neutral') { "(p - 'persona') || jsonb_build_object('persona', '$Code')" } else { "p - 'persona'" }
    $sql = "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(CASE WHEN p->>'person_id' = '$PersonId' THEN $val ELSE p END) FROM jsonb_array_elements(metadata->'facts'->'persons') p)) WHERE name = 'family';"
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $sql)
    return ($r.Code -eq 0)
}
function Get-TestPersonaFact {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$PersonId)
    if ($PersonId -match "'") { throw "Get-TestPersonaFact: kein Hochkomma in PersonId." }
    $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT COALESCE(p->>'persona', '') FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name = 'family' AND p->>'person_id' = '$PersonId';")
    return (@($q.Output | ForEach-Object { "$_".Trim() }) | Select-Object -First 1)
}

# Judge-Bundle schreiben (tests/agent/judge_bundle.json, transient = der LETZTE Lauf von n8n_test ODER orch_test) —
# die eine Adresse fuer Pfad + Format, die judge_eval.ps1 liest.
function Write-JudgeBundle {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries, [Parameter(Mandatory)][string]$RepoRoot)
    if ($Entries.Count -eq 0) { return }
    $bundlePath = Join-Path $RepoRoot 'tests\agent\judge_bundle.json'
    [System.IO.File]::WriteAllText($bundlePath, (ConvertTo-Json -InputObject @($Entries) -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "AI-Judge: $($Entries.Count) Case(s) mit Verhaltens-Rubric -> $bundlePath" -ForegroundColor Cyan
    Write-Host "  Auswerten: .\scripts\judge_eval.ps1  (Claude Haiku; kombinierter Verdikt det AND Rubric)" -ForegroundColor Cyan
}

# Chat-Memory EINER Session in ALLEN Agent-Gedaechtnissen leeren (sonst zaehlt der Mock Alt-Turns bzw.
# fasst ein LLM alte Antworten zusammen). Die <agent>_chat_memory-Tabellen legt der n8n-Memory-Node LAZY
# beim ersten Agent-Turn an -> per pg_tables FINDEN statt aufzaehlen: ein neuer Agent ist ohne Treiber-Edit
# dabei, und nur existierende Tabellen werden angefasst. SessionId = numerische chat_id ODER test_e2e…-String.
function Clear-ChatSessionMemory {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$SessionId)
    if ($SessionId -match "'") { throw "Clear-ChatSessionMemory: SessionId darf kein Hochkomma enthalten." }
    $sql = @"
DO `$clr`$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'agent' AND tablename LIKE '%\_chat\_memory' ESCAPE '\'
  LOOP
    EXECUTE format('DELETE FROM agent.%I WHERE session_id = %L', t, '$SessionId');
  END LOOP;
END `$clr`$;
"@
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $sql)
    if ($r.Code -ne 0) { throw "Session-Memory-Clear fehlgeschlagen: $($r.Output -join "`n")" }
}

# Optionaler Haushalts-Onboarding-Vorzustand eines Cases (Case-Feld "onboarding": completed|unknown|skipped).
# Self-contained je Case: der Fixture-Seed setzt alle Sektionen auf completed; Faelle, die einen NEUEN Nutzer
# brauchen (Guide: "wo fangen wir an", "Haushalt ueberspringen"), setzen unknown. EINE Stelle fuer real_ingress_test,
# n8n_test und mock_route_test. Ungueltiger Wert -> throw (der Treiber wertet den Case als FAIL).
function Set-TestHouseholdOnboarding {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Status)
    if ($Status -notin @('completed', 'unknown', 'skipped')) { throw "Unbekannter onboarding-Wert '$Status' (erwartet completed|unknown|skipped)." }
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', "UPDATE agent.guide_onboarding_state SET status = '$Status', status_changed_at = now();")
    if ($r.Code -ne 0) { throw "Onboarding-Vorbereitung fehlgeschlagen: $($r.Output -join "`n")" }
}

# Optionaler Paket-Onboarding-Vorzustand eines Cases (Case-Feld "package_onboarding": {"<pkg>.<section_key>":
# "unknown"|"skipped"|"completed"}), z. B. ein offener Finanz-Bereich fuer "Bereich Konten ist fertig" (Live-Befund
# 2026-10-24). Paket-frei: setzt ZUERST alle Sektionen jedes <pkg>.onboarding_state auf completed (Case-Isolation,
# der Fixture-Seed laeuft nur einmal je Lauf), dann die genannten. $Sections = $null -> nur der Reset; Treiber rufen
# ihn nur, wenn der Case das Feld traegt ODER ein frueherer Case es trug (sonst kein Extra-psql je Case).
# Ungueltiger Key/Wert -> throw (der Treiber wertet den Case als FAIL).
function Set-TestPackageOnboarding {
    param([Parameter(Mandatory)][string]$Container, $Sections)
    $sql = @"
DO `$`$ DECLARE s text; BEGIN
  FOR s IN SELECT table_schema FROM information_schema.tables WHERE table_name = 'onboarding_state' AND table_schema <> 'agent' LOOP
    EXECUTE format('UPDATE %I.onboarding_state SET status = ''completed'' WHERE status <> ''completed''', s);
  END LOOP;
END `$`$;
"@
    if ($Sections) {
        foreach ($p in $Sections.PSObject.Properties) {
            if ($p.Name -notmatch '^([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)$') { throw "Unbekannter package_onboarding-Key '$($p.Name)' (erwartet <pkg>.<section_key>)." }
            $pkg = $Matches[1]; $sec = $Matches[2]; $st = [string]$p.Value
            if ($st -notin @('completed', 'unknown', 'skipped')) { throw "Unbekannter package_onboarding-Wert '$st' (erwartet completed|unknown|skipped)." }
            # Vertippter Bereich darf nicht still 0 Zeilen treffen (sonst prueft der Case einen nie hergestellten Zustand).
            $sql += "`nDO `$`$ DECLARE n int; BEGIN UPDATE $pkg.onboarding_state SET status = '$st', status_changed_at = now() WHERE section_key = '$sec'; GET DIAGNOSTICS n = ROW_COUNT; IF n = 0 THEN RAISE EXCEPTION 'package_onboarding: Bereich $pkg.$sec existiert nicht'; END IF; END `$`$;"
        }
    }
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $sql)
    if ($r.Code -ne 0) { throw "Paket-Onboarding-Vorbereitung fehlgeschlagen: $($r.Output -join "`n")" }
}

# --- Paketfreie Treiber-Helfer (Phase E): kein Test-Treiber nennt ein Paket -------------------------
# Route-Agenten = die provides.agents aller Manifeste (dieselbe Lese-+Pruefstelle wie build.ps1:
# scripts/build/lib/agent_routing.ps1, 'orchestrator' ausgeschlossen, nach order sortiert).
# Throw bei Vertrags-Verstoss (wie der Build) oder leerer Liste (eine leere Menge darf nie still "passen").
function Get-TestRouteAgent {
    . (Join-Path $PSScriptRoot '..\build\lib\agent_routing.ps1')   # in der fn: kein Scope-Leck fuer andere Konsumenten
    $repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
    $routing = Get-AgentRouting (Get-PackageManifest $repoRoot)
    if ($routing.Errors.Count -gt 0) { throw ("provides.agents-Vertrag verletzt:`n  " + ($routing.Errors -join "`n  ")) }
    if (@($routing.List).Count -eq 0) { throw "Keine Route-Agenten in packages/*/manifest.json gefunden." }
    return ,@($routing.List)
}

# Agent-Test-Vorbereitung (n8n_test + mock_route_test + e2e_test, EINE Stelle): der Test-Absender ist IMMER der gepairte
# Fixture-Owner (wie produktiv: der Owner schreibt dem Bot). Eine Zufalls-chat_id gehoerte keiner Person — dann
# blieben per-Person-Gates zu, Haushalts-Schreibwege (adults_only, owner_only) lehnten ab und Agenten fragten
# "wer schreibt?" statt zu handeln (real 2026-10-20: estate/guide-Goldens). Die Case-Isolation haelt das Leeren der
# Chat-Memory je Case. Dazu fuer JEDES Ziel die Fixtures + abgeschlossenes Onboarding (idempotent; die Agenten-
# Eingangs-Gates leiten sonst auf /onboarding um, der Monitor braucht die FX-Kurse); ein Case kann den
# Haushalts-Onboarding-Zustand per "onboarding" ueberschreiben (Set-TestHouseholdOnboarding).
# Das Substrat traegt immer alle Pakete (bootstrap_test_n8n.ps1 --packages all) — der Seed setzt sie voraus.
function Initialize-AgentTestState {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$RepoRoot)
    Clear-HitlPending -Container $Container
    Clear-ThinkingLease -Container $Container
    Set-OwnerTelegramPairing -Container $Container
    $seedRes = Invoke-TestN8nPsqlFile -Container $Container -HostFile (Join-Path $RepoRoot 'tests\fixtures\util_seed_test_fixtures.sql')
    if ($seedRes.Code -ne 0) { throw "Fixture-Seed fehlgeschlagen: $($seedRes.Output -join "`n")" }
}

# Ziel-Workflow eines Treibers gegen die Route-Agenten aufloesen: Route-Agent -> sein Eintrag; der Orchestrator
# -> $null (eigener Ingress-Pfad); alles andere -> Abbruch statt stiller Default.
function Resolve-TestTarget {
    param([Parameter(Mandatory)]$RouteAgents, [Parameter(Mandatory)][string]$TargetWorkflow)
    if ($TargetWorkflow -eq 'agent.orchestrator.main_route') { return $null }
    $hit = @($RouteAgents | Where-Object { "agent.$($_.Name)" -eq $TargetWorkflow })
    if ($hit.Count -ne 1) {
        throw "Ziel '$TargetWorkflow' ist weder der Orchestrator noch ein Route-Agent (provides.agents: $(@($RouteAgents | ForEach-Object { "agent.$($_.Name)" }) -join ', '))."
    }
    return $hit[0]
}

# Welche Route-Agenten hat der Orchestrator gerufen? $Tools = Node-Namen aus dem runData (Get-ToolCall),
# Ergebnis = Agent-Namen in Routing-Reihenfolge. Node-Name aus Get-AgentCallNodeName (dieselbe Funktion
# baut ihn im Orchestrator).
function Get-RoutedAgent {
    param([AllowEmptyCollection()][string[]]$Tools = @(), [Parameter(Mandatory)]$RouteAgents)
    . (Join-Path $PSScriptRoot '..\build\lib\agent_routing.ps1')
    return @($RouteAgents | Where-Object { $Tools -contains (Get-AgentCallNodeName $_.Name) } | ForEach-Object { [string]$_.Name })
}

# Route-Verdikt eines Cases: erwartet X <=> genau [X] geroutet; leer (auch JSON-null) <=> nichts geroutet.
# Ein Erwartungswert, der kein Route-Agent ist (Tippfehler), failt mit eigener Meldung.
function Test-ExpectedRoute {
    param([AllowEmptyCollection()][string[]]$Routed = @(), [string]$Expected, [Parameter(Mandatory)]$RouteAgents)
    if ($Expected -and -not (@($RouteAgents | ForEach-Object { [string]$_.Name }) -contains $Expected)) {
        Write-Host "    FEHLER: expected_route '$Expected' ist kein Route-Agent (provides.agents)." -ForegroundColor Red
        return $false
    }
    if ($Expected) { return ($Routed.Count -eq 1 -and $Routed[0] -eq $Expected) }
    return ($Routed.Count -eq 0)
}

# DIE zentrale Weg-C-Mechanik: auf die neue Ziel-Execution (id > $AfterId) warten und sie zum
# Terminalstatus treiben, indem JEDES auftauchende HITL-Gate (sendMessage mit inline_keyboard) ueber
# die abgefangene, signierte Resume-URL mit der gewuenschten Entscheidung aufgeloest wird:
#   $Approve=$false  -> decline (Routing-Tiers: Tool nimmt 'cancelled', kein Write)
#   $Approve=$true   -> approve (E2E-Tier: der Write laeuft echt durch; mehrere Gates pro Lauf moeglich)
# Korrelation race-frei: globale monotone Exec-id (Gate-id > $AfterId) + vor dem Feuern geleertes
# Mock-Log (Clear-MockTelegramRequests). Resolvte Gates werden getrackt (kein Doppel-Resume).
# Liefert das Terminal-Execution-Detail (mit .data) oder $null (Timeout ohne Execution).
function Wait-ExecResolvingGates {
    param(
        [Parameter(Mandatory)][string]$WfId,
        [Parameter(Mandatory)][int]$AfterId,
        [Parameter(Mandatory)][bool]$Approve,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BridgeUrl,
        [Parameter(Mandatory)][string]$ApiKey,
        [int]$TimeoutSec = 90
    )
    $headers = @{ 'X-N8N-API-KEY' = $ApiKey }
    $resumed = @{}
    $start = Get-Date
    $cand = $null
    while ($true) {
        try {
            $list = (Invoke-RestMethod -Uri "$BridgeUrl/api/v1/executions?workflowId=$WfId&limit=20" -Headers $headers -Method Get).data
            $cand = $list | Where-Object { [int]$_.id -gt $AfterId } | Sort-Object { [int]$_.id } | Select-Object -First 1
        } catch { $cand = $null }

        # Jedes neu aufgetauchte Gate aufloesen (Schutz vor False-PASS: Gate-id MUSS > $AfterId sein,
        # sonst gehoert die Nachricht zu einem aelteren Lauf).
        foreach ($m in (Get-MockTelegramRequests -Container $Container)) {
            if ($m.method -ne 'sendMessage' -or -not $m.body.reply_markup) { continue }
            $url = $null
            try { $url = Get-HitlResumeUrl -Request $m -Approved $Approve -BridgeUrl $BridgeUrl } catch { continue }
            $gid = Get-HitlExecId -Url $url
            if ($gid -le $AfterId -or $resumed.ContainsKey($gid)) { continue }
            try { Invoke-HitlResume -Url $url | Out-Null; $resumed[$gid] = $true } catch { }
        }

        if ($cand -and $cand.status -ne 'running' -and $cand.status -ne 'new' -and $cand.status -ne 'waiting') {
            return Invoke-RestMethod -Uri "$BridgeUrl/api/v1/executions/$($cand.id)?includeData=true" -Headers $headers -Method Get
        }
        if (((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            if ($cand) { return Invoke-RestMethod -Uri "$BridgeUrl/api/v1/executions/$($cand.id)?includeData=true" -Headers $headers -Method Get }
            return $null
        }
        Start-Sleep -Milliseconds 1000
    }
}

# --- Textkatalog-Asserts (Phase C): Telegram-Texte gegen den getrackten Katalog pruefen ---------------------------
# Tests vergleichen nie fest verdrahtete deutsche Teilstrings, sondern die FESTEN Teilstuecke eines Katalog-Texts
# (Platzhalter {name} und Zeilenumbrueche trennen; Stuecke >= 2 Zeichen). So bleibt ein Test gruen, wenn Mina den
# koreanischen Wortlaut verbessert, und faellt, wenn eine Sprache falsch ankommt. Quelle: packages/<pkg>/locales/<lang>.json.
$script:CatalogCache = @{}
function Get-CatalogText {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Lang)
    $pkg = $Key.Split('.')[0]
    $ck = "$pkg|$Lang"
    if (-not $script:CatalogCache.ContainsKey($ck)) {
        $root = git -C $PSScriptRoot rev-parse --show-toplevel
        $p = Join-Path $root "packages\$pkg\locales\$Lang.json"
        $script:CatalogCache[$ck] = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    }
    $v = $script:CatalogCache[$ck].$Key
    if ($null -eq $v) { throw "Get-CatalogText: Key '$Key' fehlt in packages/$pkg/locales/$Lang.json" }
    [string]$v
}
function Get-CatalogFragments {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Lang, [int]$MinLength = 2)
    @((Get-CatalogText $Key $Lang) -split '\{\w+\}|\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge $MinLength })
}
# Telegram escapt Legacy-Markdown (_ * ` [) mit Backslash -> fuer den Vergleich zuruecknehmen.
function ConvertFrom-TgEscaped([string]$Text) { [regex]::Replace([string]$Text, '\\([_*`\[])', '$1') }
# $true, wenn ALLE festen Stuecke des Keys (in $Lang, ohne -Lang in irgendeiner Katalogsprache) im Text stehen.
function Test-TextHasKey {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Key, [string]$Lang)
    $plain = ConvertFrom-TgEscaped $Text
    $langs = if ($Lang) { @($Lang) } else { @('de', 'en', 'ko') }
    foreach ($l in $langs) {
        $frags = Get-CatalogFragments $Key $l
        if ($frags.Count -gt 0 -and @($frags | Where-Object { -not $plain.Contains($_) }).Count -eq 0) { return $true }
    }
    return $false
}
