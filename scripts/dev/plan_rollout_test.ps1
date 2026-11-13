#Requires -Version 5.1
# plan_rollout_test.ps1 — gratis: geführte Abfolge am Laufende echter Orchestrator-Läufe (Mock-LLM, Mock-Telegram).
# Prüft: genau eine Rollout-Nachricht nach der Antwort, keine bei offener Karte oder Rückfrage, Antwort kommt auch bei Fehler im Sub,
# Übergabe-Liste nicht doppelt, Bestandsplan bekommt Schritt 0. Laufzeit-Szenarien (Repo-scenarios bleibt unberührt).
# Voraussetzung: Substrat + enable_mock_llm.ps1 + enable_mock_telegram.ps1. Usage: .\scripts\dev\plan_rollout_test.ps1 [-Id rr1] [-ForceAbortId rr1]. Exit = Anzahl roter Fälle.
param([string[]]$Id, [string]$ForceAbortId, [int]$Timeout = 120)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\..\lib\dotenv.ps1"
Read-DotEnvLines (Join-Path $RepoRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection; $N8nUrl = $conn.Url; $ApiKey = $conn.ApiKey; $Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_llm -or -not $state.mock_telegram) { throw 'Mock-LLM und Mock-Telegram aktivieren.' }
Assert-LlmGatewayUpstream -Container $Container -Expect mock
$Id = @($Id | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Invoke-Sql([string]$Sql) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "rollout_$([guid]::NewGuid().ToString('N')).sql"
    try { [IO.File]::WriteAllText($tmp, $Sql, $Utf8NoBom); $r = Invoke-TestN8nPsqlFile -Container $Container -HostFile $tmp -PsqlArgs @('-q', '-tA') }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    if ($r.Code -ne 0) { throw "SQL fehlgeschlagen: $Sql`n$($r.Output -join "`n")" }
    return ((@($r.Output) | ForEach-Object { "$_" }) -join "`n").Trim()
}
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
    # Messung errorWorkflow: Claim laeuft mit onError continue, also ohne Fehler-Workflow.
    Assert-Equal @(Get-Sends | Where-Object { [string]$_.body.text -match 'core.sub_plan_rollout_next' }).Count 0 'Owner-Alarm'
 } }
 @{ id = 'rr5'; name = 'Uebergabe-Liste schon gesendet: kein Doppel'; run = {
    $tid = New-OpenHandoff
    Invoke-Sql "SELECT core.fn_handoff_overview_mark(jsonb_build_object('domain','finance','chat_id','$Owner','max_task_id','$tid'));" | Out-Null
    Send-Text 'ROLLOUTPING fuenf'
    Assert-Equal @(Get-Sends | Where-Object { [string]$_.body.text -match '__E2E__ Aufgabe' }).Count 0 'Uebergabe doppelt'
 } }
 @{ id = 'rr6'; name = 'Uebergabe-Liste als Erinnerung: offen seit, Grund, verschachtelte Texte aufgeloest'; run = {
    $null = New-OpenHandoff
    Send-Text 'ROLLOUTPING sechs'
    $list = @(Get-Sends | Where-Object { [string]$_.body.text -match 'E2E' -and ($_.body.reply_markup | ConvertTo-Json -Depth 8 -Compress) -match '"handoff:' })
    Assert-Equal $list.Count 1 'Uebergabe-Liste'
    $txt = [string]$list[0].body.text
    if ($txt -notmatch '\(offen seit heute\)' -or $txt -notmatch 'Ich erinnere dich, weil das noch offen ist\.' -or $txt -match 'core\.handoff\.') { throw "Text unerwartet: $txt" }
 } }
)
$failed = 0; $ran = 0
try {
    foreach ($c in $Cases) {
        if ($Id.Count -and $Id -notcontains $c.id) { continue }
        $ran++
        Write-Host "[$($c.id)] $($c.name)" -ForegroundColor Cyan
        try { Reset-Rollout; Test-ForceAbort $c.id $ForceAbortId; & $c.run; Write-Host '    [PASS]' -ForegroundColor Green }
        catch { $failed++; Write-CaseAbort -ErrorRecord $_ -CaseId $c.id }
    }
} finally {
    Reset-Rollout
    Invoke-Sql "UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'plan_rollout';" | Out-Null
    $tmp = Join-Path $env:TEMP "rollout_scn_$PID.json"
    [IO.File]::WriteAllText($tmp, $RawScn, $Utf8NoBom); & docker cp $tmp "${Container}:/opt/mock_llm/scenarios.json" | Out-Null; Remove-Item $tmp -Force
}
Write-AbortedCases
Write-Host "plan_rollout_test: $ran Faelle, $failed rot." -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed