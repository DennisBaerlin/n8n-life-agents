#Requires -Version 5.1
# Definition agent.advisor.cron_plan_rollout -> Build-CronAdvisorPlanRollout. Dot-gesourct von build.ps1.
# Taeglicher Nachzuegler der gefuehrten Abfolge; deterministisch, kein LLM.
function Build-CronAdvisorPlanRollout {
    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'plan_rollout'
    $gate = Build-Pg 'Cron enabled?' @(-880, 0) `
        "=SELECT core.fn_package_active('core') AND COALESCE(core.fn_config_get('core','cron_enable','plan_rollout') = 'true', false) AS enabled" `
        $null
    $on = Build-If 'Cron on?' @(-660, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-660, 200)
    $list = Build-Pg 'List chats' @(-440, 0) '=SELECT core.fn_plan_rollout_lagging()::text AS r;' $null
    $splitJs = @'
let r = {};
try { r = JSON.parse($input.first().json.r || '{}'); } catch (e) { r = {}; }
return (Array.isArray(r.chats) ? r.chats : []).map(c => ({ json: { chat_id: String(c) } }));
'@
    $split = [ordered]@{ parameters = [ordered]@{ jsCode = $splitJs }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 0); id = (New-Id); name = 'Split chats' }
    $call = Build-CallWorkflow 'Run rollout' @(0, 0) (Get-RequiredWorkflowId 'core.sub_plan_rollout_next' 'Build-CronAdvisorPlanRollout') 'core.sub_plan_rollout_next' `
        ([ordered]@{ chat_id = '={{ $json.chat_id }}'; footer_key = 'core.reminders.card_footer'; skip = 'false'; budget = 'true' }) -Mode each
    $call['onError'] = 'continueRegularOutput'
    $sticky = Build-Sticky 'Überblick' @(-1140, -320) 'Täglicher Nachzügler der geführten Abfolge' `
        'Läuft einmal am Tag im Erinnerungs-Fenster (schedule.plan_rollout, cron_enable.plan_rollout). core.fn_plan_rollout_lagging liefert die Chats mit möglichem offenem Schritt, je Chat ruft Run rollout den Sub core.sub_plan_rollout_next. Claim und Reihenfolge entscheidet der Sub. Mit budget true belegt der Claim erst dann den Tages-Slot, wenn eine Nachricht feststeht; ohne Platz werden ihre Merker freigegeben. Holt auch nach, wenn ein Lauf abgebrochen ist, und stößt für Bestandspläne einmal [Plan durchsehen] an.' 320 280
    $nodes = @($trig, $gate, $on, $off, $list, $split, $call, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?' = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?' = @{ main = @( @( E 'List chats' ), @( E 'Disabled' ) ) }
        'List chats' = @{ main = @( ,@( E 'Split chats' ) ) }
        'Split chats' = @{ main = @( ,@( E 'Run rollout' ) ) }
    }
    return Build-Workflow 'agent.advisor.cron_plan_rollout' $nodes $conns
}