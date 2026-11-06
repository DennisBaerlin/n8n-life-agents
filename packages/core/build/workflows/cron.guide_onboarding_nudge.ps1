#Requires -Version 5.1
# Definition agent.guide.cron_onboarding_nudge -> Build-CronGuideOnboardingNudge. Dot-gesourct von build.ps1.
# Roter Faden (Owner-Entscheid 2026-10-23): sanftes Nachfassen, wenn das Einrichten liegen bleibt — nach 3 Tagen
# Stillstand eine Karte, nach 10 Tagen eine letzte, dann Ruhe (bis ein neues Paket Abschnitte oeffnet). Jede Karte:
# [Weiter] (onboarding:<pkg>:<key>, derselbe Einstieg wie der Menue-Knopf) + [Nicht mehr erinnern]
# (rem:off:onboarding_nudge -> core.fn_handle_reminder_cb, die Person schaltet NUR sich selbst ab).
#
# Ablauf: scheduleTrigger (schedule.onboarding_nudge, 10:30 im Erinnerungs-Fenster) -> F9-Gate (fn_package_active(core)
#   AND cron_enable.onboarding_nudge = Konsolen-Notschalter fuer alle) -> Find nudges (core.fn_onboarding_nudges_due:
#   entscheidet + latcht, MATERIALIZED -> genau ein Aufruf) -> Split nudges (ein Item je Person) -> Load card texts
#   (Sprache der Person; Abschnitts-/Bereichsname ueber doc-Keys) -> Send nudge (je Item).
# Die Reihenfolge der Bereiche (welcher Abschnitt "als Naechstes" kommt) ist die Menue-Reihenfolge: build-time
# $OnboardingPackageOrder, als p.order an die fn -> Karte und Weiter-Knopf des /onboarding-Menues nennen denselben Schritt.
# Deterministisch, kein LLM. Cron-Credential = Haupt-RW (Build-Pg-Default): die fn liest agent.* und schreibt Latches.
function Build-CronGuideOnboardingNudge {
    $trig = Build-ScheduleTrigger @(-1320, 0) -ScheduleKey 'onboarding_nudge'

    $gate = Build-Pg 'Cron enabled?' @(-1100, 0) `
        "=SELECT core.fn_package_active('core') AND COALESCE(core.fn_config_get('core','cron_enable','onboarding_nudge') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-880, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-880, 200)

    # Menue-Reihenfolge build-time (Haushalt zuerst, dann $OnboardingPackageOrder) -> eine SQL-Konstante.
    $order = @('core') + @($OnboardingPackageOrder | ForEach-Object { [string]$_.Package })
    $orderSql = "jsonb_build_object('order', jsonb_build_array(" + (($order | ForEach-Object { "'" + $_ + "'" }) -join ', ') + "))"
    $find = Build-Pg 'Find nudges' @(-660, 0) `
        ("=WITH n AS MATERIALIZED (SELECT core.fn_onboarding_nudges_due($orderSql) AS r) SELECT n.r::text AS r FROM n;") `
        $null

    $splitJs = @'
let r = {};
try { r = JSON.parse($input.first().json.r || '{}'); } catch (e) { r = {}; }
const list = Array.isArray(r.nudges) ? r.nudges : [];
return list.map(n => ({ json: {
  chat_id: String(n.chat_id), stage: Number(n.stage), package: String(n.package), section_key: String(n.section_key),
  label_key: (n.package === 'core') ? ('core.onboarding.' + n.section_key) : (n.package + '.onboarding.' + n.section_key),
  area_key: (n.package === 'core') ? '' : (n.package + '.package.name')
} }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-440, 0)
        id = (New-Id); name = 'Split nudges'
    }

    # Texte je Person: feste Keys + Abschnitts-/Bereichsname (dynamische Keys ueber p.doc, Regel von core.fn_ui_texts_for).
    $keys = Get-UiKeysSql @('core.nudge.stage1', 'core.nudge.stage2', 'core.nudge.btn_continue', 'core.nudge.btn_stop')
    $texts = Build-Pg 'Load card texts' @(-220, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($keys), " +
         "'doc', jsonb_build_array((`$1::jsonb)->>'label_key', NULLIF((`$1::jsonb)->>'area_key', ''))))->'t' AS t;") `
        ([ordered]@{
            chat_id   = "String(`$json.chat_id || '')"
            label_key = "String(`$json.label_key || '')"
            area_key  = "String(`$json.area_key || '')"
        })

    # Text: Stufe 1 bzw. 2 ("letzte Erinnerung") mit {step} = Abschnitt (+ Bereich in Klammern, nicht beim Haushalt).
    $T = "`$('Load card texts').item.json.t"
    $S = "`$('Split nudges').item.json"
    $stepJs = "(String(($T || {})[$S.label_key] || $S.label_key) + (($S.area_key && ($T || {})[$S.area_key]) ? (' (' + ($T || {})[$S.area_key] + ')') : ''))"
    $textExpr = "={{ (($S.stage === 2) ? " + (Get-UiTextJs $T 'core.nudge.stage2') + " : " + (Get-UiTextJs $T 'core.nudge.stage1') +
                ").split('{step}').join($stepJs) }}"
    $send = New-TelegramInlineKeyboardSendNode 'Send nudge' @(0, 0) $textExpr `
        @( @{ Text = (Get-UiTextExpr $T 'core.nudge.btn_continue'); Data = "={{ 'onboarding:' + $S.package + ':' + $S.section_key }}" },
           @{ Text = (Get-UiTextExpr $T 'core.nudge.btn_stop'); Data = 'rem:off:onboarding_nudge' } ) `
        -ChatIdExpr "={{ String($S.chat_id) }}"
    $send['onError'] = 'continueRegularOutput'

    $sticky = Build-Sticky 'Überblick' @(-1360, -400) -Header 'Ablauf' `
        'Nachfassen bei liegengebliebenem Einrichten (Roter Faden, deterministisch, kein LLM)' `
        'Täglich 10:30 (schedule.onboarding_nudge, im Erinnerungs-Fenster general.reminders_from..until). F9-Gate: core aktiv UND cron_enable.onboarding_nudge (Konsolen-Notschalter für ALLE; jede Person schaltet sich selbst per [Nicht mehr erinnern] = rem:off:onboarding_nudge ab -> agent.reminder_prefs, core.fn_reminder_allowed). Find nudges = core.fn_onboarding_nudges_due (MATERIALIZED, ein Aufruf): je verbundener Person mit offenem Abschnitt in einem für sie offenen Bereich (Owner alles, Mitglied nur persönliche Bereiche und erst nach dem Haushalt) Stufe 1 nach >= 3 Tagen Stillstand, Stufe 2 (letzte) nach >= 10 Tagen und >= 7 Tage nach Stufe 1, dann Ruhe; ein neu geöffneter Abschnitt (Paket installiert) re-armt. Latch source onboarding_nudge in core.notification_state, höchstens eine Karte je Person und Lauf. Reihenfolge = Menü-Reihenfolge (build-time, p.order). Split nudges -> Load card texts (Sprache der Person, Abschnitts-/Bereichsname über doc-Keys) -> Send nudge: [Weiter] = onboarding:<pkg>:<key> (gleicher Einstieg wie der Menü-Knopf, Owner-Arm bzw. Mitglieder-Registry) + [Nicht mehr erinnern]. Send onError=continue: ein Telegram-Fehler einer Person stoppt die anderen nicht.' 420 760

    $nodes = @($trig, $gate, $ifEnabled, $off, $find, $split, $texts, $send, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @( @( E 'Find nudges' ), @( E 'Disabled' ) ) }
        'Find nudges'                 = @{ main = @( ,@( E 'Split nudges' ) ) }
        'Split nudges'                = @{ main = @( ,@( E 'Load card texts' ) ) }
        'Load card texts'             = @{ main = @( ,@( E 'Send nudge' ) ) }
    }
    return Build-Workflow 'agent.guide.cron_onboarding_nudge' $nodes $conns
}
