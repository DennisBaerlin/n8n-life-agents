# test_install_env.ps1 -- die eine Adresse fuer die Eingaben einer Test-Installation, die beide Unterbauten gleich brauchen:
# welche .env-Schluessel TEST_<x> als welcher Kern-Schluessel in die Installation gehen, und die festen Test-Schalter.
# Verwender: scripts/dev/bootstrap_test_n8n.ps1 (klassisch, Env-Datei) und scripts/lib/test_stack.ps1 (Verbund, Zusatz-Zeilen
# der Antwort-Datei ueber tests/wizard/render_ci_answers.js --extra-stdin). Test: scripts/dev/test_stack_test.ps1.
# Dot-sourcen.

# Bot-Token einer Test-Installation -- eine Adresse fuer beide Unterbauten. Ein Substrat bekommt ein ERFUNDENES Token: n8n ruft beim
# Aktivieren des Orchestrators setWebhook auf und biegt den Webhook des Bots auf die Substrat-Adresse (Dev-Profil: https://example.com/),
# ein echter Test-Bot waere danach fuer jede andere Installation stumm. Die Suiten brauchen den echten Bot nicht: sie laufen ueber
# Harness-Webhooks und den Mock-Telegram (enable_mock_telegram.ps1), CI (new_ci_env.ps1) und der Verbund tun es schon so.
# Der echte Token aus .env (TEST_TELEGRAM_BOT_TOKEN) gilt nur mit dem ausdruecklichen Schalter N8NTEST_REAL_TELEGRAM=1 (Ende-zu-Ende-Lauf
# gegen echtes Telegram); der klassische Abbau gibt den Webhook dann frei (bootstrap_test_n8n.ps1 -Down). Waechter:
# scripts/dev/test_n8n_runtime_test.ps1 (jeder Leser des .env-Tokens geht durch diese Funktion).
$script:TestInventedBotToken = '1000001:inventedTokenForTheMockTelegram00'
function Resolve-TestTelegramToken([string]$EnvToken) {
    if ($env:N8NTEST_REAL_TELEGRAM -eq '1' -and -not [string]::IsNullOrWhiteSpace($EnvToken)) { return $EnvToken.Trim() }
    return $script:TestInventedBotToken
}


# Get-TestInstallEnvMap <repo> -- feste Liste + je Paket die env-Namen aus manifest.json credentials (§3.8, env[] = der
# Kern-Env-Name; das Substrat reicht TEST_<name> -> <name>, _inject_manifest_credentials liest env-override-first). doc_lint 7b
# prueft die abgeleiteten TEST_*-Schluessel gegen .env.example mit derselben Ableitung.
function Get-TestInstallEnvMap([string]$RepoRoot) {
    $map = [ordered]@{
        'TEST_N8N_OWNER_EMAIL'    = 'N8N_OWNER_EMAIL'
        'TEST_N8N_OWNER_PASSWORD' = 'N8N_OWNER_PASSWORD'
        'TEST_N8N_ENCRYPTION_KEY' = 'N8N_ENCRYPTION_KEY'
        'TEST_PG_PASSWORD'        = 'N8N_DB_PASSWORD'
        'TEST_TELEGRAM_BOT_TOKEN' = 'TELEGRAM_BOT_TOKEN'
        'TEST_TELEGRAM_CHAT_ID'   = 'OWNER_CHAT_ID'
        'TEST_GOOGLE_API_KEY'     = 'GOOGLE_API_KEY'
        'TEST_ANTHROPIC_API_KEY'  = 'ANTHROPIC_API_KEY'
        'TEST_HARNESS_SECRET'     = 'TEST_HARNESS_SECRET'
        'TEST_OWNER_FIRST_NAME'   = 'OWNER_FIRST_NAME'
        'TEST_OWNER_LAST_NAME'    = 'OWNER_LAST_NAME'
        'TEST_OWNER_BIRTH_DATE'   = 'OWNER_BIRTH_DATE'
        'TEST_OWNER_LANGUAGE'     = 'OWNER_LANGUAGE'
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Sort-Object Name)) {
        $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
        if (-not (Test-Path $mfPath)) { continue }
        $mf = [System.IO.File]::ReadAllText($mfPath, $utf8) | ConvertFrom-Json
        if ($null -eq $mf.credentials) { continue }
        foreach ($credProp in ($mf.credentials.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) {
            if ($null -eq $credProp.Value.env) { continue }
            # Property-NAME = der Kern-Env-Key (z. B. ADZUNA_APP_ID); .field ist das n8n-Credential-Datenfeld, nicht der Env-Name.
            foreach ($envKeyProp in $credProp.Value.env.PSObject.Properties) {
                if (-not $map.Contains("TEST_$($envKeyProp.Name)")) { $map["TEST_$($envKeyProp.Name)"] = [string]$envKeyProp.Name }
            }
        }
    }
    return $map
}

# Get-TestDevSwitches -- feste Schalter jeder Test-Installation, Reihenfolge = Zeilen-Reihenfolge der Env-Datei:
#   TEST_HARNESS_HEADER=X-Test-Auth     die Harness-Webhooks nutzen httpHeaderAuth und alle Test-Skripte senden X-Test-Auth;
#                                       inject_credentials.sh nimmt sonst x-harness-secret -> infra_test bekaeme 403.
#   LIFEAGENTS_HITL_CHAT_APPROVAL       true nur mit -HitlChatApproval: das Substrat hat keine echte Domain, die Selbst-Probe in
#                                       deploy_workflows.sh (_hitl_chat_approval) bliebe sonst bei Link-Knoepfen (Prod-Weg ohne Domain).
#   LIFEAGENTS_DEPLOY_FULL              1 nur mit -FullDeploy (Not-Schalter, sonst nur neue/geaenderte Workflows).
#   LLM_GATEWAY_KEEPALIVE_HOURS=0       ein stundenlang laufendes Substrat stupste sonst bis zu 24 h den Cache auf dem
#                                       Entwickler-Schluessel an (kostet ohne Nutzen); die Mechanik prueft llm_gateway_test (k).
#   LLM_GATEWAY_SERIAL_TOOLS            nur wenn gesetzt (0|1): Probelauf parallele Werkzeug-Aufrufe; ungesetzt = Standard an.
#   BOT_PROFILE_PHOTO=0                 eine Installation mit echtem Test-Bot setzte ihm sonst ein Bild (bot_profile_photo_test
#                                       prueft die Mechanik gegen den Mock).
#   TELEGRAM_WEBHOOK_TAKEOVER=1         der Test-Bot ist vom vorigen oder einem parallelen Substrat noch verbunden; ohne den
#                                       Schalter bricht die Erstinstallation vor jeder Aenderung ab (telegram_webhook_preflight).
function Get-TestDevSwitches {
    param([switch]$HitlChatApproval, [switch]$FullDeploy, [string]$SerialTools = '')
    if ($SerialTools -and $SerialTools -notin @('0', '1')) { throw "LLM_GATEWAY_SERIAL_TOOLS nur 0 oder 1, nicht '$SerialTools'." }
    $s = [ordered]@{
        'TEST_HARNESS_HEADER'           = 'X-Test-Auth'
        'LIFEAGENTS_HITL_CHAT_APPROVAL' = $(if ($HitlChatApproval) { 'true' } else { 'false' })
        'LIFEAGENTS_DEPLOY_FULL'        = $(if ($FullDeploy) { '1' } else { '0' })
        'LLM_GATEWAY_KEEPALIVE_HOURS'   = '0'
    }
    if ($SerialTools) { $s['LLM_GATEWAY_SERIAL_TOOLS'] = $SerialTools }
    $s['BOT_PROFILE_PHOTO'] = '0'
    $s['TELEGRAM_WEBHOOK_TAKEOVER'] = '1'
    return $s
}

# ConvertTo-TestEnvFileLines -- Zeilen der Env-Datei des klassischen Unterbaus (provision.sh --unattended liest sie mit
# install_answers_load, nie gesourct): gesetzte TEST_*-Werte als Kern-Schluessel, danach die Test-Schalter; jeder Wert in
# einfachen Anfuehrungszeichen ('\'' fuer ein '). Der Verbund nimmt dieselben Paare ueber ConvertTo-TestStackExtra.
function ConvertTo-TestEnvFileLines {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)][hashtable]$Values, [switch]$HitlChatApproval, [switch]$FullDeploy, [string]$SerialTools = '')
    $q = { param($v) "'" + ($v -replace "'", "'\''") + "'" }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Map.Keys) {
        $v = [string]$Values[$k]
        if ($v) { $out.Add("$($Map[$k])=$(& $q $v)") }
    }
    $sw = Get-TestDevSwitches -HitlChatApproval:$HitlChatApproval -FullDeploy:$FullDeploy -SerialTools $SerialTools
    foreach ($k in $sw.Keys) { $out.Add("$k=$(& $q $sw[$k])") }
    return $out
}