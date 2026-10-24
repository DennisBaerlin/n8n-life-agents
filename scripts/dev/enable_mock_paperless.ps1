#Requires -Version 5.1
# enable_mock_paperless.ps1 — den Mock-Paperless-Server in der laufenden Test-n8n-Instanz scharf schalten
# (paperless Phase 2; Muster enable_mock_telegram.ps1). Operiert auf einem BEREITS hochgefahrenen Substrat
# (scripts/dev/bootstrap_test_n8n.ps1) — der byte-identische Install-Pfad bleibt unberuehrt.
#
# Was es tut (idempotent):
#   1) tests/mock_paperless/server.js in den Container kopieren (-> /opt/mock_paperless/server.js).
#   2) Den Mock als transiente systemd-unit `n8ntest-mock-paperless` starten (127.0.0.1:<port>) + Health-Probe.
#   3) core.config paperless.general.paperless_url auf den Mock setzen (Container-psql) — die Werkzeuge lesen die
#      Adresse zur Laufzeit (core.fn_config_get), kein Redeploy noetig.
#   4) Die Token-Credential 'Paperless-NGX API' (httpHeaderAuth) per REST-PATCH auf den Mock-Token umstellen — das
#      ECHTE Owner-Token (TEST_PAPERLESS_API_TOKEN) geht so nie an den Mock (Plan-Reviewer F5).
#   5) Einen `mock_paperless`-Block ins State-File schreiben (infra_test-Cases mit requires=mock_paperless).
#
# -Down: Unit stoppen, paperless_url auf den vorherigen Wert, Credential zurueck auf 'Token <TEST_PAPERLESS_API_TOKEN>'
#        (falls in .env gesetzt), State-Block entfernen.
#
# Vorbedingung: laufendes Substrat mit installiertem paperless-Paket UND der Credential 'Paperless-NGX API'
# (inject_credentials legt sie nur an, wenn TEST_PAPERLESS_API_TOKEN in .env steht — beliebiger Wert genuegt).
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
    throw "Kein N8N_API_KEY im State — die Credential-Umstellung braucht die REST-API. Substrat neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset"
}

$MockPort   = if ($env:N8NTEST_MOCK_PL_PORT) { $env:N8NTEST_MOCK_PL_PORT } else { '8092' }
$MockUrl    = "http://127.0.0.1:$MockPort"
$MockToken  = 'mock-paperless-token'
$MockLog    = '/tmp/mock_paperless.jsonl'
$Unit       = 'n8ntest-mock-paperless'
$ServerHost = Join-Path $RepoRoot 'tests\mock_paperless\server.js'
$ServerInC  = '/opt/mock_paperless/server.js'
$StateFile  = Join-Path $RepoRoot '.local\n8ntest_state.json'
$Headers    = @{ 'X-N8N-API-KEY' = $ApiKey }
$CredName   = 'Paperless-NGX API'

function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}
function Get-EnvValue([string]$name) {
    $line = (Get-Content "$RepoRoot\.env" | Where-Object { $_ -match "^\s*$([regex]::Escape($name))=" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $v = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}
function Get-PaperlessCredId {
    $resp = Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials?limit=250" -Headers $Headers -Method Get
    $c = $resp.data | Where-Object { $_.type -eq 'httpHeaderAuth' -and $_.name -eq $CredName } | Select-Object -First 1
    return $c.id
}
function Set-PaperlessToken([string]$CredId, [string]$HeaderValue) {
    # allowedDomains = Pflicht-Feldform von httpHeaderAuth (n8n 2.21.7, auf 2.44.4 bestaetigt) (wie inject_credentials.sh _cred_assemble_data).
    $body = @{ name = $CredName; type = 'httpHeaderAuth'; data = @{ name = 'Authorization'; value = $HeaderValue; allowedDomains = '' } } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$N8nUrl/api/v1/credentials/$CredId" -Headers $Headers -Method Patch `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}
# paperless_url lesen/setzen (Container-psql, Superuser). Der Wert ist eine URL ohne Hochkomma -> sicher literal.
function Get-PaperlessUrl {
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-t', '-A', '-c', "SELECT value FROM core.config WHERE category='general' AND key='paperless_url';")
    if ($r.Code -ne 0) { throw "paperless_url lesen fehlgeschlagen: $($r.Output -join "`n")" }
    return (($r.Output -join '').Trim())
}
function Set-PaperlessUrl([string]$Url) {
    if ($Url -match "'") { throw "paperless_url darf kein Hochkomma enthalten." }
    $sql = "UPDATE core.config SET value='$Url' WHERE category='general' AND key='paperless_url' AND package='paperless';"
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-t', '-A', '-c', $sql)
    if ($r.Code -ne 0 -or (($r.Output -join '') -notmatch 'UPDATE 1')) { throw "paperless_url setzen fehlgeschlagen (Paket paperless installiert?): $($r.Output -join "`n")" }
}
function Read-State { [System.IO.File]::ReadAllText($StateFile, $Utf8NoBom) | ConvertFrom-Json }
function Write-StateMock([object]$state, [object]$mockBlock) {
    $ordered = [ordered]@{}
    foreach ($p in $state.PSObject.Properties) { if ($p.Name -ne 'mock_paperless') { $ordered[$p.Name] = $p.Value } }
    if ($null -ne $mockBlock) { $ordered['mock_paperless'] = $mockBlock }
    [System.IO.File]::WriteAllText($StateFile, ([pscustomobject]$ordered | ConvertTo-Json), $Utf8NoBom)
}

$credId = Get-PaperlessCredId
if (-not $credId) { throw "Keine Credential '$CredName' gefunden — TEST_PAPERLESS_API_TOKEN in .env setzen (beliebiger Wert) und das Substrat neu bauen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset" }

# --- Teardown ---------------------------------------------------------------------------------------
if ($Down) {
    Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
    Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
    $prevUrl = ''
    if (Test-Path $StateFile) { $st = Read-State; if ($st.mock_paperless) { $prevUrl = [string]$st.mock_paperless.previous_url } }
    Set-PaperlessUrl $prevUrl
    $real = Get-EnvValue 'TEST_PAPERLESS_API_TOKEN'
    if ($real) { Set-PaperlessToken $credId "Token $real" }
    if (Test-Path $StateFile) { Write-StateMock (Read-State) $null }
    Write-Host "Mock-Paperless deaktiviert: Unit gestoppt, paperless_url -> '$prevUrl', Token zurueckgesetzt, State-Block entfernt."
    return
}

# --- 1) server.js kopieren ----------------------------------------------------------------------------
if (-not (Test-Path $ServerHost)) { throw "Mock-Server nicht gefunden: $ServerHost" }
$r = Invoke-Native docker @('exec',$Container,'mkdir','-p','/opt/mock_paperless')
if ($r.Code -ne 0) { throw "mkdir /opt/mock_paperless fehlgeschlagen: $($r.Output -join "`n")" }
$r = Invoke-Native docker @('cp',$ServerHost,"${Container}:$ServerInC")
if ($r.Code -ne 0) { throw "docker cp server.js fehlgeschlagen: $($r.Output -join "`n")" }

# --- 2) Mock als transiente systemd-unit starten (Reload: stop+start) ----------------------------------
$nodeBin = ((Invoke-Native docker @('exec',$Container,'sh','-c','command -v node')).Output -join '').Trim()
if (-not $nodeBin) { throw "node im Container nicht gefunden (n8n bringt Node mit — Substrat ok?)." }
Invoke-Native docker @('exec',$Container,'systemctl','stop',$Unit) | Out-Null
Invoke-Native docker @('exec',$Container,'systemctl','reset-failed',$Unit) | Out-Null
Write-Host "Starte Mock-Paperless (systemd-unit $Unit, 127.0.0.1:$MockPort) ..."
$r = Invoke-Native docker @('exec',$Container,'systemd-run',"--unit=$Unit",'--collect',
    "--setenv=N8NTEST_MOCK_PL_PORT=$MockPort","--setenv=N8NTEST_MOCK_PL_LOG=$MockLog","--setenv=N8NTEST_MOCK_PL_TOKEN=$MockToken",
    $nodeBin,$ServerInC)
if ($r.Code -ne 0) { throw "systemd-run $Unit fehlgeschlagen: $($r.Output -join "`n")" }
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    $p = Invoke-Native docker @('exec',$Container,'sh','-c',"curl -sf http://127.0.0.1:$MockPort/__health >/dev/null 2>&1 && echo ok || echo no")
    if ((($p.Output -join '').Trim()) -eq 'ok') { $ready = $true; break }
    Start-Sleep -Milliseconds 400
}
if (-not $ready) {
    $jr = Invoke-Native docker @('exec',$Container,'journalctl','-u',$Unit,'--no-pager','-n','20')
    throw "Mock-Paperless wurde nicht bereit (Health-Probe Timeout). journalctl:`n$($jr.Output -join "`n")"
}

# --- 3) paperless_url umbiegen (vorherigen Wert fuer -Down merken; ein schon gemockter Wert wird nicht gemerkt) ---
$prev = Get-PaperlessUrl
$state = Read-State
if ($state.mock_paperless) { $prev = [string]$state.mock_paperless.previous_url }
if ($prev -eq $MockUrl) { $prev = '' }   # abgebrochener Vorlauf hatte die Adresse schon umgebogen -> nie den Mock als "vorher" merken
Set-PaperlessUrl $MockUrl
Write-Host "paperless_url -> $MockUrl"

# --- 4) Token-Credential auf den Mock-Token -----------------------------------------------------------
Set-PaperlessToken $credId "Token $MockToken"
Write-Host "Credential '$CredName' ($credId) -> Mock-Token."

# --- 5) State-Block ----------------------------------------------------------------------------------
Write-StateMock (Read-State) ([ordered]@{ port = [int]$MockPort; url = $MockUrl; log = $MockLog; unit = $Unit; cred_id = $credId; previous_url = $prev })

Write-Host ""
Write-Host "============================================================"
Write-Host "  Mock-Paperless aktiv"
Write-Host "  Unit:      $Unit  (127.0.0.1:$MockPort, im Container)"
Write-Host "  Log:       $MockLog"
Write-Host ""
Write-Host "  Werkzeuge deterministisch pruefen:  .\scripts\infra_test.ps1"
Write-Host "  deaktivieren:                       .\scripts\dev\enable_mock_paperless.ps1 -Down"
Write-Host "============================================================"
