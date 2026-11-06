#Requires -Version 5.1
# app_endpoint_test.ps1 — DETERMINISTISCHER, GRATIS Test des Mini-App-Eingangs (docs/package-contract.md §3.12).
# Feuert echte HTTP-Anfragen an den produktiven Webhook von core.main_app_serve im laufenden Substrat:
#   (1) GET  -> 200, text/html, n8n-CSP-Sandkasten-Header, Renderer eingesetzt (kein /*__UI_RENDER_LIB__*/ mehr);
#   (2) POST Muell (text/plain) -> {ok:false, code:malformed} als JSON, KEIN Fehler-Alert (Mock-Telegram leer);
#   (3) POST mit gefaelschter initData -> {ok:false, code:bad_signature};
#   (4) POST mit gueltiger initData des Owners (hier signiert mit dem Substrat-Schluessel aus core.app_secret)
#       -> Navigation ok:true mit ui.lang + jeder Bildschirm aus core.app_screens ok:true mit view; (4b) Startseite:
#       ok-Banner „Alles in Ordnung“ genau dann, wenn kein alert/warn-Banner da ist (nur mit Daten im Substrat);
#   (5) Origin: null (opaker Ursprung der Sandkasten-Seite) -> CORS-Antwort-Header vorhanden;
#   (5b) der Installer-Seed: core.app_screens == app_screens-Bloecke aller Manifeste;
#   (6) die Repo-Adresse (Platzhalter) ist live nicht registriert (Pfad je Instanz geheim).
# Die Adresse kommt aus dem ECHTEN Installer-Code (deploy_workflows.sh _app_path) im Container.
# Voraussetzung: laufendes Substrat (bootstrap_test_n8n.ps1); Mock-Telegram optional (sonst entfaellt der Alert-Check).
# Usage:  .\scripts\dev\app_endpoint_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$N8nUrl = $conn.Url
$Container = $conn.Container
$state = Get-TestN8nState

$failed = 0
function Fail($m) { Write-Host "    [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Pass($m) { Write-Host "    [PASS] $m" -ForegroundColor Green }

# --- Adresse aus dem Installer-Code (eine Adresse fuer Workflow-Patch, Menue-Knopf und diesen Test) -------------------
$lib = '/usr/local/lib/lifeagents'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$appPath = (& docker exec $Container bash -c ". $lib/provisioning/lib/common.sh; . $lib/provisioning/lib/deploy_workflows.sh; _app_path" 2>$null | Select-Object -Last 1)
$ErrorActionPreference = $prev
if ("$appPath" -notmatch '^app-[0-9a-f-]{36}$') { throw "App-Pfad nicht ableitbar ('$appPath') — Substrat ohne INGRESS_ID_KEY?" }
$AppUrl = "$N8nUrl/webhook/$appPath"
if ($Verbose) { Write-Host "  App-URL: $AppUrl" -ForegroundColor DarkGray }

function Invoke-App([string]$Method, [string]$Body, [hashtable]$Extra = @{}) {
    $h = @{} + $Extra
    $p = @{ Uri = $AppUrl; Method = $Method; UseBasicParsing = $true; Headers = $h; TimeoutSec = 30 }
    if ($Method -eq 'POST') { $p.Body = $Utf8NoBom.GetBytes($Body); $p.ContentType = 'text/plain;charset=UTF-8' }
    try { return Invoke-WebRequest @p } catch { return $_.Exception.Response }
}
function Get-Json($resp) { try { return ($Utf8NoBom.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json) } catch { return $null } }

# initData wie Telegram signieren (core.telegram.org/bots/webapps): Schluessel = core.app_secret (Substrat).
$q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "SELECT encode(webapp_key, 'hex') FROM core.app_secret WHERE id;")
$keyHex = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-f]{64}$' } | Select-Object -First 1)
function New-InitData([long]$Uid, [string]$Lang = 'de', [switch]$Forge) {
    $auth = [string][long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $user = '{"id":' + $Uid + ',"first_name":"Test","language_code":"' + $Lang + '"}'
    $dcs = "auth_date=$auth`nuser=$user"
    $key = [byte[]]::new(32); for ($i = 0; $i -lt 32; $i++) { $key[$i] = [Convert]::ToByte($keyHex.Substring($i * 2, 2), 16) }
    $hm = [System.Security.Cryptography.HMACSHA256]::new($key)
    $hash = -join ($hm.ComputeHash($Utf8NoBom.GetBytes($dcs)) | ForEach-Object { $_.ToString('x2') })
    if ($Forge) { $hash = ('0' * 64) }
    return "auth_date=$auth&user=$([Uri]::EscapeDataString($user))&hash=$hash"
}

Write-Host ""
Write-Host "Mini-App-Eingang (core.main_app_serve) gegen das Substrat"
Write-Host ("-" * 64)
$hasMockTg = [bool]$state.mock_telegram
if ($hasMockTg) { Clear-MockTelegramRequests -Container $Container }

# (1) Seite
$r = Invoke-App GET ''
if ($null -eq $r -or [int]$r.StatusCode -ne 200) { Fail "GET: Status $([int]$r.StatusCode) (erwartet 200)" }
else {
    $html = $Utf8NoBom.GetString($r.RawContentStream.ToArray())
    if ("$($r.Headers['Content-Type'])" -notmatch '^text/html') { Fail "GET: Content-Type '$($r.Headers['Content-Type'])'" }
    if ("$($r.Headers['Content-Security-Policy'])" -notmatch 'sandbox') { Fail "GET: kein CSP-sandbox-Header (n8n-Version geaendert? Sticky 'Doc: Sandkasten' pruefen)" }
    if ($html -notmatch 'function uiRender\(' -or $html.Contains('/*__UI_RENDER_LIB__*/')) { Fail 'GET: Renderer nicht eingesetzt' }
    if ($failed -eq 0) { Pass 'GET liefert die Seite (text/html, Sandkasten-CSP, Renderer eingesetzt)' }
}

# (2) Muell
$r = Invoke-App POST 'das ist kein JSON'
$j = Get-Json $r
if ($j.ok -ne $false -or $j.code -ne 'malformed') { Fail "Muell-Body: $($j | ConvertTo-Json -Compress -Depth 5)" } else { Pass 'Muell-Body -> malformed' }

# (3) Faelschung
$owner = $script:TestOwnerTelegramUid
Set-OwnerTelegramPairing -Container $Container
if (-not $keyHex) { Fail 'core.app_secret leer — der Deploy hat den Schluessel nicht gesetzt (_ensure_app_secret)' }
else {
    $r = Invoke-App POST (@{ init_data = (New-InitData $owner -Forge) } | ConvertTo-Json -Compress)
    $j = Get-Json $r
    if ($j.code -ne 'bad_signature') { Fail "Gefaelschte initData: $($j | ConvertTo-Json -Compress -Depth 5)" } else { Pass 'gefaelschte initData -> bad_signature' }

    # (4) gueltig: Navigation + Bildschirm
    $r = Invoke-App POST (@{ init_data = (New-InitData $owner) } | ConvertTo-Json -Compress) @{ Origin = 'null' }
    $j = Get-Json $r
    if ($j.ok -ne $true -or -not $j.ui.lang) { Fail "Navigation: $($j | ConvertTo-Json -Compress -Depth 6)" }
    else { Pass "Navigation ok (Sprache $($j.ui.lang), Bildschirme: $(@($j.screens | ForEach-Object { $_.screen }) -join ', '))" }
    # (4b) Startseiten-Banner (UX-Gesamtkonzept P4): ok-Banner „Alles in Ordnung“ genau dann, wenn kein alert/warn da ist;
    #      sein Text kommt als echter Katalog-Text mit. Ohne Bildschirm mit Daten (leeres Substrat) gibt es keine Startseite.
    if (@($j.screens).Count -gt 0) {
        if ($null -eq $j.first -or $null -eq $j.first.view) { Fail 'Startseite: first fehlt trotz Bildschirmen (erster Bildschirm wird nicht mitgeliefert)' }
        else {
            $bn = @($j.first.view.banners)
            $okB = @($bn | Where-Object { $_.state -eq 'ok' }); $hint = @($bn | Where-Object { $_.state -in @('alert', 'warn') })
            if ($hint.Count -eq 0 -and $okB.Count -ne 1) { Fail "Startseite ohne Hinweis: genau ein ok-Banner erwartet, got $($bn | ConvertTo-Json -Compress -Depth 6)" }
            elseif ($hint.Count -gt 0 -and $okB.Count -ne 0) { Fail "Startseite mit Hinweis: kein ok-Banner erwartet, got $($bn | ConvertTo-Json -Compress -Depth 6)" }
            elseif ($okB.Count -eq 1 -and ($okB[0].text.value -ne 'core.app.all_good' -or -not $j.ui.t.'core.app.all_good' -or $j.ui.t.'core.app.all_good' -eq 'core.app.all_good')) {
                Fail "ok-Banner: Text core.app.all_good fehlt oder ohne Katalog-Text ($($okB[0] | ConvertTo-Json -Compress -Depth 6))" }
            else { Pass "Startseiten-Banner stimmig ($($hint.Count) Hinweis(e), $($okB.Count) ok)" }
        }
    } else { Write-Host '    [SKIP] Startseiten-Banner: keine Bildschirme mit Daten im Substrat' -ForegroundColor DarkGray }
    # (5) CORS fuer den opaken Ursprung der Sandkasten-Seite
    $acao = "$($r.Headers['Access-Control-Allow-Origin'])"
    if (-not $acao) { Fail 'Origin: null -> kein Access-Control-Allow-Origin (die Seite im Sandkasten bekaeme keine Daten)' } else { Pass "CORS fuer Origin null: '$acao'" }

    # jeder registrierte Bildschirm (Registry, nicht die Navigation: die zeigt auf leerem Substrat nur Nicht-Leere)
    $qs = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', 'SELECT screen FROM core.app_screens ORDER BY ord, screen;')
    $screens = @($qs.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[a-z][a-z0-9_]*$' })
    if ($screens.Count -eq 0) { Fail 'core.app_screens leer' }
    foreach ($s in $screens) {
        $r = Invoke-App POST (@{ init_data = (New-InitData $owner); screen = $s } | ConvertTo-Json -Compress)
        $j = Get-Json $r
        if ($j.ok -ne $true -or $null -eq $j.view -or $j.view.ok -ne $true) { Fail "Bildschirm ${s}: $($j | ConvertTo-Json -Compress -Depth 6)" }
        else { Pass "Bildschirm $s ok (View-Modell geliefert)" }
    }
}

# (5b) Seeder: core.app_screens der installierten Instanz == app_screens-Bloecke aller Manifeste (handler_fn, ord,
# icon; kein Rest-Eintrag) — der echte Installer-Seed (_seed_app_screens) statt eines Direkt-INSERTs.
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$want = @{}
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $m = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
    if (-not $m.app_screens) { continue }
    foreach ($pr in $m.app_screens.PSObject.Properties) {
        if ($pr.Name -eq '_comment') { continue }
        $want[$pr.Name] = "$($pr.Value.handler_fn)|$($pr.Value.ord)|$($pr.Value.icon)"
    }
}
$q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-F', '|', '-c', 'SELECT screen, handler_fn, ord, icon FROM core.app_screens ORDER BY screen;')
$have = @{}
foreach ($line in @($q.Output)) { $f = "$line".Trim() -split '\|'; if ($f.Count -eq 4) { $have[$f[0]] = "$($f[1])|$($f[2])|$($f[3])" } }
$diff = @(@($want.Keys) + @($have.Keys) | Sort-Object -Unique | Where-Object { $want[$_] -ne $have[$_] })
if ($want.Count -eq 0) { Fail 'kein app_screens-Block in den Manifesten gefunden' }
elseif ($diff.Count) { Fail "core.app_screens weicht von den Manifesten ab: $($diff | ForEach-Object { "$_ (Manifest '$($want[$_])', DB '$($have[$_])')" })" }
else { Pass "Seeder: core.app_screens == Manifeste ($($want.Count) Bildschirm(e))" }

# (6) Repo-Platzhalter ist live keine Adresse
$p = $null
try { $p = Invoke-WebRequest -Uri "$N8nUrl/webhook/__APP_PATH__" -Method GET -UseBasicParsing -TimeoutSec 15 } catch { $p = $_.Exception.Response }
if ($p -and [int]$p.StatusCode -eq 200) { Fail 'Platzhalter-Adresse /webhook/__APP_PATH__ antwortet (Pfad nicht je Instanz ersetzt)' } else { Pass 'Platzhalter-Adresse nicht registriert' }

# (2b) kein Owner-Alert durch Muell/Faelschung
if ($hasMockTg) {
    Start-Sleep -Seconds 2
    $alerts = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' })
    if ($alerts.Count -gt 0) { Fail "Anfragen aus dem Internet loesten $($alerts.Count) Telegram-Nachricht(en) aus (Fehler-Alert?)" } else { Pass 'kein Fehler-Alert durch Muell/Faelschung' }
} else {
    Write-Host '    (Mock-Telegram nicht aktiv -> Alert-Check entfaellt)' -ForegroundColor DarkGray
}

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host 'app_endpoint_test: OK' -ForegroundColor Green } else { Write-Host "app_endpoint_test: $failed Fehler" -ForegroundColor Red }
exit $failed
