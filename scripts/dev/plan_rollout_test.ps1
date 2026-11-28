#Requires -Version 5.1
# plan_rollout_test.ps1 — gratis: geführte Abfolge am Laufende echter Orchestrator-Läufe (Mock-LLM, Mock-Telegram).
# Prüft: genau eine Rollout-Nachricht nach der Antwort, keine bei offener Karte oder Rückfrage, Antwort kommt auch bei Fehler im Sub,
# Übergabe-Liste nicht doppelt, Bestandsplan bekommt Schritt 0, Wortlaut der Liste samt Folge-Zeile aus dem Textkatalog, stilles
# Warten auf offene Einträge (zurückgestellte halten nicht auf). Laufzeit-Szenarien (Repo-scenarios bleibt unberührt).
# Voraussetzung: Substrat + enable_mock_llm.ps1 + enable_mock_telegram.ps1; liest .env.
# Usage: .\scripts\dev\plan_rollout_test.ps1 [-Id rr1] [-ForceAbortId rr1] [-Timeout 120]. Exit = Anzahl roter Fälle.
# Seiteneffekte im Substrat: leert finance-Übergaben und -Pläne (agent.handoff_tasks, agent.advisor_plans), agent.hitl_pending und die
# plan_rollout-Merker, schaltet cron_enable plan_rollout am Ende aus; ersetzt kurz core.advisors.entry_effects_fn und scenarios.json
# der Mock-LLM (danach zurück).
param([string[]]$Id, [string]$ForceAbortId, [int]$Timeout = 120)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\..\lib\dotenv.ps1"
Import-DotEnvVariables (Join-Path $RepoRoot '.env')
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection; $N8nUrl = $conn.Url; $ApiKey = $conn.ApiKey; $Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_llm -or -not $state.mock_telegram) { throw 'Mock-LLM und Mock-Telegram aktivieren.' }
Assert-LlmGatewayUpstream -Container $Container -Expect mock
$Id = @($Id | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

. "$PSScriptRoot\..\lib\test_common.ps1"
function Invoke-Sql([string]$Sql) { Invoke-SqlViaTempFile -Container $Container -Sql $Sql }
function Assert-Equal($Actual, $Expected, [string]$Msg) { if ("$Actual" -ne "$Expected") { throw "${Msg}: erwartet '$Expected', ist '$Actual'" } }
function Add-Scn($List) {
    $raw = (& docker exec $Container cat /opt/mock_llm/scenarios.json) -join "`n"
    $new = @($raw | ConvertFrom-Json) + @($List)
    $tmp = Join-Path $env:TEMP "rollout_scn_$PID.json"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $new -Depth 12), $Utf8NoBom)
    & docker cp $tmp "${Container}:/opt/mock_llm/scenarios.json" | Out-Null
    Remove-Item $tmp -Force
}
$RawScn = (& docker exec $Container cat /opt/mock_llm/scenarios.json) -join "`n"
Add-Scn @(@{ match = 'ROLLOUTPING'; final = 'Alles klar, erledigt.' }, @{ match = 'ROLLOUTFRAGE'; final = 'Meinst du wirklich?' })

Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot
$Owner = [long]$script:TestOwnerTelegramUid
$Ing = Resolve-OrchestratorIngress -BridgeUrl $N8nUrl -ApiKey $ApiKey
function Reset-Rollout {
    Invoke-Sql @"
UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'plan_rollout';
DELETE FROM agent.handoff_tasks WHERE domain = 'finance';
DELETE FROM agent.advisor_plans WHERE domain = 'finance';
DELETE FROM agent.hitl_pending;
DELETE FROM core.notification_state WHERE source = 'plan_rollout';
"@ | Out-Null
    Clear-ChatSessionMemory -Container $Container -SessionId "$Owner"
    Clear-MockRequestLogs -Container $Container
}
function New-ActivePlan { Invoke-Sql "INSERT INTO agent.advisor_plans (domain, plan_name, status, version, plan_md) VALUES ('finance', '__E2E__ Rollout', 'active', 1, 'x');" | Out-Null }
function Send-Text([string]$Text) {
    $base = Get-MaxExecId -WfId $Ing.OrchWfId -BridgeUrl $N8nUrl -ApiKey $ApiKey
    Send-TelegramIngress -IngressUrl $Ing.Url -Secret $Ing.Secret -ChatId $Owner -FromUid $Owner -Text $Text | Out-Null
    $null = Wait-ExecResolvingGates -WfId $Ing.OrchWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8nUrl -ApiKey $ApiKey -TimeoutSec $Timeout
    Start-Sleep -Seconds 4
}
function Get-Sends { @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' -and -not [string]::IsNullOrEmpty([string]$_.body.text) }) }
function Get-Rollout { @(Get-Sends | Where-Object { $_.body.reply_markup -and ($_.body.reply_markup | ConvertTo-Json -Depth 8 -Compress) -match 'plan:scan:finance' }) }
# Aktiver, durchgesehener Plan plus eine offene Uebergabe-Aufgabe des Owners; Rueckgabe = Aufgaben-id.
function New-OpenHandoff {
    New-ActivePlan
    Invoke-Sql "UPDATE agent.advisor_plans SET synced_at = now() WHERE domain = 'finance' AND status = 'active';" | Out-Null
    $p = Invoke-Sql "SELECT agent.fn_owner_person_id();"
    Invoke-Sql "INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance', 'finance', '$p', 's', 'other', '__E2E__ Aufgabe') RETURNING id;"
}
function Has-Answer([string]$T) { @(Get-Sends | Where-Object { [string]$_.body.text -match [regex]::Escape($T) }).Count -ge 1 }
# Erwartete Texte kommen aus dem Katalog (Key), nie als Wortlaut im Test; Telegram-Markdown-Escapes (\_) zaehlen nicht.
$Catalog = [IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\locales\de.json'), $Utf8NoBom) | ConvertFrom-Json
function Get-Text([string]$Key, [hashtable]$Params = @{}) {
    $t = [string]$Catalog.$Key
    if (-not $t) { throw "Katalog-Key fehlt: $Key" }
    foreach ($k in $Params.Keys) { $t = $t.Replace("{$k}", [string]$Params[$k]) }
    return $t
}
function Get-PlainText($Send) { return ([string]$Send.body.text).Replace('\', '') }
function Get-ButtonData($Send) { if ($Send.body.reply_markup) { return ($Send.body.reply_markup | ConvertTo-Json -Depth 8 -Compress) } else { return '' } }
function Get-HandoffList { @(Get-Sends | Where-Object { (Get-ButtonData $_) -match '"handoff:finance:' }) }
function Get-ExpectedList([string]$Why) { return Get-Text 'core.handoff.overview' @{ why = (Get-Text $Why); list = '1. __E2E__ Aufgabe' } }
# Folge-Zeile der Liste: die Paket-fn wird fuer den Fall durch eine mit fester Konten-Zahl ersetzt (Registry), danach zurueckgesetzt.
$EffectsFn = Invoke-Sql "SELECT entry_effects_fn FROM core.advisors WHERE domain = 'finance';"
# Ein abgebrochener Lauf kann den Ersatz stehen gelassen haben: nie ihn als Original zuruecksetzen.
if ("$EffectsFn" -match 'fn_e2e_effects_stub') { $EffectsFn = 'finance.fn_entry_effects' }
function Set-EffectStub([int]$Accounts) {
    Invoke-Sql "CREATE OR REPLACE FUNCTION finance.fn_e2e_effects_stub(p text) RETURNS jsonb LANGUAGE sql AS 'SELECT jsonb_build_object(''accounts'', $Accounts)'; UPDATE core.advisors SET entry_effects_fn = 'finance.fn_e2e_effects_stub' WHERE domain = 'finance';" | Out-Null
}
function Reset-EffectStub {
    $value = if ("$EffectsFn".Trim()) { "'$("$EffectsFn".Trim())'" } else { 'NULL' }
    Invoke-Sql "UPDATE core.advisors SET entry_effects_fn = $value WHERE domain = 'finance'; DROP FUNCTION IF EXISTS finance.fn_e2e_effects_stub(text);" | Out-Null
}

$Cases = @(
 @{ id = 'rr1'; name = 'Antwort, danach genau eine Rollout-Nachricht (Bestandsplan: Schritt 0)'; run = {
    New-ActivePlan; Send-Text 'ROLLOUTPING eins'
    if (-not (Has-Answer 'Alles klar')) { throw 'Antwort fehlt' }
    Assert-Equal @(Get-Rollout).Count 1 'Rollout-Nachrichten'
    Assert-Equal (Invoke-Sql "SELECT core.fn_plan_rollout_latch('finance:household:1:0');") 'done' 'Merker festgeschrieben'
 } }
 @{ id = 'rr2'; name = 'Karte offen: keine Rollout-Nachricht'; run = {
    New-ActivePlan
    Invoke-Sql "INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at, released_at) VALUES ($Owner, 'rr2', now() + interval '5 minutes', NULL);" | Out-Null
    $orig = Invoke-Sql "SELECT count(*) FROM agent.hitl_pending;"
    $null = $orig
    # Mit offener Karte beantwortet der Pre-Router die Nachricht selbst; die Abfolge bleibt still.
    Send-Text 'ROLLOUTPING zwei'
    Assert-Equal @(Get-Rollout).Count 0 'Rollout-Nachrichten'
 } }
 @{ id = 'rr3'; name = 'Antwort endet mit Frage: keine Rollout-Nachricht'; run = {
    New-ActivePlan; Send-Text 'ROLLOUTFRAGE drei'
    if (-not (Has-Answer 'Meinst du wirklich')) { throw 'Antwort fehlt' }
    Assert-Equal @(Get-Rollout).Count 0 'Rollout-Nachrichten'
 } }
 @{ id = 'rr4'; name = 'Fehler im Sub: Antwort kommt trotzdem, kein Owner-Alarm'; run = {
    New-ActivePlan
    Invoke-Sql 'ALTER FUNCTION core.fn_plan_rollout_claim(jsonb) RENAME TO fn_plan_rollout_claim_off;' | Out-Null
    try { Send-Text 'ROLLOUTPING vier' } finally { Invoke-Sql 'ALTER FUNCTION core.fn_plan_rollout_claim_off(jsonb) RENAME TO fn_plan_rollout_claim;' | Out-Null }
    if (-not (Has-Answer 'Alles klar')) { throw 'Antwort fehlt' }
    Assert-Equal @(Get-Rollout).Count 0 'Rollout-Nachrichten'
    # errorWorkflow greift hier nicht: Claim laeuft mit onError continue, also ohne Fehler-Workflow.
    Assert-Equal @(Get-Sends | Where-Object { [string]$_.body.text -match 'core.sub_plan_rollout_next' }).Count 0 'Owner-Alarm'
 } }
 @{ id = 'rr5'; name = 'Uebergabe-Liste schon gesendet: kein Doppel'; run = {
    $tid = New-OpenHandoff
    Invoke-Sql "SELECT core.fn_handoff_overview_mark(jsonb_build_object('domain','finance','chat_id','$Owner','max_task_id','$tid'));" | Out-Null
    Send-Text 'ROLLOUTPING fuenf'
    Assert-Equal @(Get-Sends | Where-Object { [string]$_.body.text -match '__E2E__ Aufgabe' }).Count 0 'Uebergabe doppelt'
 } }
 @{ id = 'rr6'; name = 'Uebergabe-Liste aus der Abfolge: Katalog-Text mit verschachteltem Grund, Knopf, ohne Folge-Zeile ohne Warnung'; run = {
    $null = New-OpenHandoff
    Set-EffectStub 0
    Send-Text 'ROLLOUTPING sechs'
    $list = Get-HandoffList
    Assert-Equal @($list).Count 1 'Uebergabe-Liste'
    # why_rollout_one steckt verschachtelt in core.handoff.overview; ein unaufgeloester Key bliebe sichtbar.
    Assert-Equal (Get-PlainText $list[0]) (Get-ExpectedList 'core.handoff.why_rollout_one') 'Text der Liste'
    if ((Get-ButtonData $list[0]) -notmatch [regex]::Escape((Get-Text 'core.handoff.btn_go'))) { throw "Knopf-Beschriftung fehlt: $(Get-ButtonData $list[0])" }
 } }
 @{ id = 'rr7'; name = 'Uebergabe-Liste mit Folge-Zeile, wenn Konten eine Warnung tragen'; run = {
    $null = New-OpenHandoff
    Set-EffectStub 2
    Send-Text 'ROLLOUTPING sieben'
    $list = Get-HandoffList
    Assert-Equal @($list).Count 1 'Uebergabe-Liste'
    $txt = Get-PlainText $list[0]
    $effect = Get-Text 'core.handoff.effect' @{ n = 2 }
    if (-not $txt.StartsWith((Get-ExpectedList 'core.handoff.why_rollout_one')) -or -not $txt.TrimEnd().EndsWith($effect)) { throw "Folge-Zeile fehlt oder steht falsch: $txt" }
 } }
 @{ id = 'rr8'; name = 'Stilles Warten ohne Frist auf einen offenen Eintrag; zurueckgestellt haelt nicht auf'; run = {
    $tid = "$(New-OpenHandoff)".Trim()
    Invoke-Sql "SELECT core.fn_handoff_overview_mark(jsonb_build_object('domain','finance','chat_id','$Owner','max_task_id','$tid')); UPDATE core.notification_state SET last_fired_at = now() - interval '90 days' WHERE source = 'plan_rollout';" | Out-Null
    Send-Text 'ROLLOUTPING acht'
    if (-not (Has-Answer 'Alles klar')) { throw 'Antwort fehlt' }
    $follow = @(Get-Sends | Where-Object { Get-ButtonData $_ })
    Assert-Equal $follow.Count 0 'Nachrichten der Abfolge, solange der Eintrag offen ist'
    Invoke-Sql "UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'pay_until_amount' WHERE id = $tid;" | Out-Null
    Clear-MockRequestLogs -Container $Container
    Send-Text 'ROLLOUTPING neun'
    $finish = @(Get-Sends | Where-Object { (Get-PlainText $_) -eq (Get-Text 'core.rollout.finish') })
    Assert-Equal $finish.Count 1 'Schluss der Abfolge nach dem Zurueckstellen'
 } }
)
$failed = 0; $ran = 0
try {
    # Jede genannte id muss es geben: sonst liefe ein Tippfehler still als kleinerer, gruener Lauf (wie scripts/infra_test.ps1).
    $missing = @($Id | Where-Object { $_ -notin @($Cases | ForEach-Object { $_.id }) })
    if ($missing.Count) { throw "Testfall nicht gefunden: $($missing -join ', ')." }
    foreach ($c in $Cases) {
        if ($Id.Count -and $Id -notcontains $c.id) { continue }
        $ran++
        Write-Host "[$($c.id)] $($c.name)" -ForegroundColor Cyan
        try { Reset-Rollout; Reset-EffectStub; Test-ForceAbort $c.id $ForceAbortId; & $c.run; Write-Host '    [PASS]' -ForegroundColor Green }
        catch { $failed++; Write-CaseAbort -ErrorRecord $_ -CaseId $c.id }
    }
} finally {
    Reset-Rollout
    Reset-EffectStub
    Invoke-Sql "UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'plan_rollout';" | Out-Null
    $tmp = Join-Path $env:TEMP "rollout_scn_$PID.json"
    [IO.File]::WriteAllText($tmp, $RawScn, $Utf8NoBom); & docker cp $tmp "${Container}:/opt/mock_llm/scenarios.json" | Out-Null; Remove-Item $tmp -Force
}
Write-AbortedCases
Write-Host "plan_rollout_test: $ran Faelle, $failed rot." -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed