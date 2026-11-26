#Requires -Version 5.1
# Definition agent.advisor.cron_resume_nudge -> Build-CronAdvisorResumeNudge. Dot-gesourct von build.ps1.
# Erinnerung an eine angefangene Beratung: Stufe 1 nach 4, Stufe 2 nach 14 Tagen Pause, dann Ruhe; einmal an offene
# Uebergabe-Punkte nach dem Veroeffentlichen. Entscheidung, Merker und Text-Struktur macht core.fn_advisor_resume_due; dieser
# Workflow rendert nur (Sprache der Person, uiRender) und sendet. Deterministisch, kein LLM.
# order/plan_order = dieselbe build-time-Quelle wie der Orchestrator (Get-NextStepOrder) -> Erinnerung und Gruss-Knopf nennen
# denselben Schritt (Tor R6 in der fn).
function Build-CronAdvisorResumeNudge {
    $trig = Build-ScheduleTrigger @(-1320, 0) -ScheduleKey 'advisor_resume'
    $gate = Build-Pg 'Cron enabled?' @(-1100, 0) `
        "=SELECT core.fn_package_active('core') AND COALESCE(core.fn_config_get('core','cron_enable','advisor_resume') = 'true', false) AS enabled" `
        $null
    $on = Build-If 'Cron on?' @(-880, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-880, 200)

    $nextOrder = Get-NextStepOrder $RepoRoot
    $lit = { param($xs) 'jsonb_build_array(' + ((@($xs) | ForEach-Object { "'" + ([string]$_ -replace '[^a-z0-9_:]', '') + "'" }) -join ', ') + ')' }
    $pSql = "jsonb_build_object('order', $(& $lit $nextOrder.Order), 'plan_order', $(& $lit $nextOrder.PlanOrder))"
    $find = Build-Pg 'Find reminders' @(-660, 0) `
        ("=WITH n AS MATERIALIZED (SELECT core.fn_advisor_resume_due($pSql) AS r) SELECT n.r::text AS r FROM n;") `
        $null

    # Ein Item je Person mit genau einem Haupt-Knopf aus der fn; [Nicht mehr erinnern] setzt der Send-Knoten fest.
    # keys = alle Text-Verweise der Nachricht (auch verschachtelte tpl in params) + Knopf-Texte.
    $splitJs = @'
let r = {};
try { r = JSON.parse($input.first().json.r || '{}'); } catch (e) { r = {}; }
const list = Array.isArray(r.items) ? r.items : [];
const nested = (x) => (x && typeof x === 'object') ? Object.values(x.params || {}).flatMap(p => (p && typeof p === 'object' && p.kind === 'tpl') ? [p.value, ...nested(p)] : []) : [];
return list.filter(m => Array.isArray(m.buttons) && m.buttons.length === 1).map(m => ({ json: Object.assign({}, m, {
  chat_id: String(m.chat_id),
  keys: [...new Set([...(m.msg || []).flatMap(x => [x && x.value, ...nested(x)]), ...m.buttons.map(b => b.text_key), 'core.nudge.btn_stop'].filter(Boolean))]
}) }));
'@
    $split = [ordered]@{ parameters = [ordered]@{ jsCode = $splitJs }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-440, 0); id = (New-Id); name = 'Split reminders' }

    $keysExpr = Get-UiKeysSql $script:UiRenderKeys
    $load = Build-Pg 'Load texts' @(-220, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', ((`$1::jsonb)->'ui_keys') || to_jsonb($keysExpr)))::text AS ui;") `
        ([ordered]@{ chat_id = '$json.chat_id'; ui_keys = '$json.keys' })

    $buildJs = (Get-UiRenderLibJs) + @'

const m = $('Split reminders').item.json;
const U = uiRender(JSON.parse($json.ui || '{}'));
return { json: { chat_id: m.chat_id, text: U.msg(m.msg || []),
  buttons: (m.buttons || []).map(b => ({ text: U.t(b.text_key), data: String(b.data) })), stop: U.t('core.nudge.btn_stop') } };
'@
    $build = [ordered]@{ parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = $buildJs }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(0, 0); id = (New-Id); name = 'Build message' }

    $B = "`$('Build message').item.json"
    $send = New-TelegramInlineKeyboardSendNode 'Send reminder' @(220, 0) "={{ $B.text }}" `
        @( @{ Text = "={{ $B.buttons[0].text }}"; Data = "={{ $B.buttons[0].data }}" },
           @{ Text = "={{ $B.stop }}"; Data = 'rem:off:advisor_resume' } ) `
        -ChatIdExpr "={{ String($B.chat_id) }}"
    $send['onError'] = 'continueRegularOutput'

    $sticky = Build-Sticky 'Überblick' @(-1360, -420) -Header 'Ablauf' `
        'Erinnerung an eine angefangene Beratung (deterministisch, kein LLM)' `
        'Täglich 10:45 (schedule.advisor_resume, im Erinnerungs-Fenster, nach dem Einrichtungs-Nachfassen 10:30). Tor: core aktiv UND cron_enable.advisor_resume (Notschalter für alle; jede Person schaltet sich per [Nicht mehr erinnern] = rem:off:advisor_resume ab, wieder an über /reminders). Find reminders = core.fn_advisor_resume_due (MATERIALIZED, ein Aufruf): entscheidet, setzt Merker und Budget und liefert je Person höchstens eine Nachricht als Text-Struktur. Plan-Entwurf ruht 4 Tage -> Stufe 1, 14 Tage -> letzte Stufe, dann Ruhe. An die Liste noch offener vereinbarter Einträge erinnert er nie (sie kommt einmal nach dem Veröffentlichen, danach still im Menü). Nur wenn der nächste Schritt (core.fn_get_next_step, gleiche Reihenfolge wie beim Gruß) genau diese Beratung ist, keine Karte offen ist, der Bot nicht gerade antwortet, heute kein Gruß-Vorschlag und keine Einrichtungs-Erinnerung kam. Split reminders -> Load texts (Sprache der Person, auch verschachtelte Text-Verweise) -> Build message (uiRender) -> Send reminder: [Weiter] = plan:resume:<domain>:<plan_id> (startet den Berater wie der Plan-Knopf), dazu [Nicht mehr erinnern]. Der Merker steht schon vor dem Senden: scheitert Telegram, geht diese eine Erinnerung verloren (wie beim Einrichtungs-Nachfassen). Send onError=continue: ein Fehler bei einer Person stoppt die anderen nicht.' 440 820

    $nodes = @($trig, $gate, $on, $off, $find, $split, $load, $build, $send, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @( @( E 'Find reminders' ), @( E 'Disabled' ) ) }
        'Find reminders'              = @{ main = @( ,@( E 'Split reminders' ) ) }
        'Split reminders'             = @{ main = @( ,@( E 'Load texts' ) ) }
        'Load texts'                  = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message'               = @{ main = @( ,@( E 'Send reminder' ) ) }
    }
    return Build-Workflow 'agent.advisor.cron_resume_nudge' $nodes $conns
}
