#Requires -Version 5.1
# Definition agent.estate.cron_review_register -> Build-EstateCronReviewRegister. Dot-gesourct von build.ps1.
# WS-4: monatlicher Jahres-Review des Vorsorge-Registers. Ruft core.fn_advisor_review_evaluate('estate',
# NULL, '{}') -> die generische Core-Advisor-Engine dispatcht auf estate.fn_advisor_review (Registry
# core.advisors) und LATCHT deren Alerts (Register-Staleness > advisor.estate_review_days, fehlende Vorsorge-
# Dokumente je Erwachsenem, finance-Nachlass-Feld-Gaps [guarded]) gegen die geteilte core.notification_state.
# send=true NUR bei NEUEM Breach -> der Cron ist SELBST-STILL (Default always-on, aber die Meldung kommt nur,
# wenn etwas Neues auftaucht) -> keine Spam-Gefahr trotz monatlicher Kadenz.
#
# BEGRUENDETE ABWEICHUNG vom career-Erbmodell (Opus-M4, Plan groovy-watching-wave): die geteilten Advisor-Crons
# (agent.advisor.cron_drift_check/cron_review via New-AdvisorCron) sind default-OFF und NUR ueber den
# finance-/career-Publish-Knopf einschaltbar. estate hat KEIN Publish -> ohne eigenen Cron liefe der Review
# still nie. Also ein schlanker EIGEN-Cron (Skelett wie cron.remind_case_tasks: F9-Gate -> Eval -> Build ->
# Anything? -> Phrase/Choose/Send), der NUR die estate-Domaene evaluiert (household -> person_id NULL, KEINE
# Get-AdvisorFanoutCte noetig). KEINE Wiederverwendung von New-AdvisorCron: dessen Gate/Schedule-Lookup ist
# hart auf das Paket 'core' verdrahtet und es traegt einen Abschalten-Button (cron_off, den estate nicht will).
# Der Phrase/Choose/Model-Schwanz ist der geteilte New-AdvisorPhrasingTail (lib/build_helpers.ps1, wie New-AdvisorCron;
# model.advisor_review bei JEDEM Lauf aus core.config).
#
# ALWAYS-ON + HAUSHALTS-ERINNERUNG (Roter Faden Paket B): cron_enable.review_register=true, Eintrag in cron_labels.list
# -> der Owner schaltet sie per [Erinnerung abschalten] an der Karte (cron_off:review_register) oder in /reminders;
# Konsole: lifeagents config set cron_enable review_register false. (cron_remind_case_tasks bleibt Pflicht = nie schaltbar.)
# ROLLE: laeuft unter dem Haupt-RW-Credential (Build-Pg-Default = WRITE) — die Eval-fn SCHREIBT Latch-State
# (Praezedenz cron.advisor_common.ps1; die SQL ist entwickler-geschrieben + deterministisch, kein LLM-SELECT).
function Build-EstateCronReviewRegister {
    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'review_register'

    # F9-Gate (WS-1/Phase 4a): nur wenn Paket aktiv UND cron_enable -> sonst No-op (fail-closed). DB entscheidet.
    $gate = Build-Pg 'Cron enabled?' @(-880, 0) `
        "=SELECT core.fn_package_active('estate') AND COALESCE(core.fn_config_get('estate','cron_enable','review_register') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-660, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-440, 200)

    # Generischer Eval-Pass NUR fuer die estate-Domaene (household -> person_id NULL, keine Fan-out-CTE). Der
    # Wrapper: Registry-Lookup estate -> estate.fn_advisor_review, dyn. EXECUTE, dann LATCH je Alert gegen
    # core.notification_state (source='advisor:estate') -> send=true gdw mind. EIN Breach NEU ist. jsonb ::text
    # (n8n-Pg-Node-Quirk, Muster cron.advisor_review.ps1).
    # Textkatalog Phase C: die Texte (Owner-Sprache; feste Keys + alle tpl-Keys der Alerts) in DERSELBEN Anweisung
    # wie der Latch (MATERIALIZED) — ein Ladefehler rollt den Latch mit zurueck.
    $keys = Get-UiKeysSql (@('estate.advisor.review_intro', 'core.reminders.btn_off') + $script:UiRenderKeys)
    $evaluate = Build-Pg 'Evaluate review' @(-440, 0) `
        ("=WITH ev AS MATERIALIZED (SELECT core.fn_advisor_review_evaluate('estate', NULL, '{}'::jsonb) AS r) " +
         "SELECT ev.r::text AS r, core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys), 'doc', ev.r->'alerts'))::text AS ui FROM ev") `
        $null

    # Deterministischer Message-Text (Fallback + LLM-Input) — Code, kein LLM. NUR bei send=true (neuer Breach)
    # aus der paket-gelieferten alert.msg-Struktur (geteilter Renderer, Owner-Sprache); sonst report=false -> Quiet run.
    $buildJs = (Get-UiRenderLibJs) + @'
const r = JSON.parse($json.r || '{}');
const ui = JSON.parse($json.ui || '{}');
const U = uiRender(ui);
const send = r && r.send === true;
const alerts = (r && Array.isArray(r.alerts)) ? r.alerts : [];
const parts = alerts.map(a => (a && Array.isArray(a.msg)) ? U.msg(a.msg).trim() : (a && a.text ? String(a.text).trim() : '')).filter(Boolean);
const language_label = ui.language_label || 'en';
if (!send || parts.length === 0) { return [{ json: { det_text: '', report: false, language_label } }]; }
return [{ json: { det_text: U.t('estate.advisor.review_intro') + '\n\n' + parts.join('\n\n'), report: true, language_label, btn_off: U.t('core.reminders.btn_off') } }];
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 0)
        id = (New-Id); name = 'Build message'
    }

    # Stiller Lauf (keine neuen Breaches) -> keine Message.
    $ifReport = Build-If 'Anything to report?' @(0, 0) '={{ $json.report }}' 'true' 'equals' 'boolean'
    $quiet = Build-NoOp 'Quiet run' @(180, 200)

    # LLM formuliert warm/behutsam um (Vorsorge-Sensibilitaet); Zahlen/Items unveraendert; Fehler -> der
    # deterministische Text (Choose text). Geteilter Schwanz New-AdvisorPhrasingTail (model.advisor_review bei JEDEM
    # Lauf; Load model config sitzt VOR Evaluate review -> Latch-Write erst nach erfolgreichem Laden).
    $tail = New-AdvisorPhrasingTail -ConfigPackage 'core' -ConfigKey 'advisor_review' -Effort low `
        -PromptLead 'Rewrite the following yearly estate-preparedness reminder as a short, warm, reassuring Telegram message, written in the language {language}. Keep German legal terms (e.g. Vorsorgevollmacht, Patientenverfuegung) in German. PLAIN TEXT only (no markdown, no asterisks). Keep EVERY number and every concrete item EXACTLY as given. Maximum 16 lines. Text:\n\n'

    # Nudge an den Owner mit [Erinnerung abschalten] (Roter Faden Paket B: Haushalts-Erinnerung in cron_labels.list,
    # Abmelden an der Nachricht selbst; cron_off:review_register -> core.fn_set_cron_enable, wieder an in /reminders).
    # Text escapt der Helper.
    $send = New-TelegramInlineKeyboardSendNode 'Send review' @(620, 0) "={{ `$json.message }}" `
        @( @{ Text = "={{ `$('Build message').first().json.btn_off }}"; Data = 'cron_off:review_register' } )

    $stickyOverview = Build-Sticky 'Überblick' @(-1140, -360) `
        'agent.estate.cron_review_register — monatlicher Jahres-Review (always-on, Latch-selbst-still)' `
        'Schedule (schedule.review_register, Default monatlich 1./10:05) -> Cron enabled? (fn_package_active(estate) AND cron_enable.review_register; Default true always-on; der Owner schaltet per [Erinnerung abschalten] = cron_off:review_register an der Karte oder in /reminders, Roter Faden Paket B) -> Load model config (model.advisor_review bei JEDEM Lauf; VOR dem Latch-Write) -> Evaluate review (core.fn_advisor_review_evaluate(estate, NULL, {}) -> Engine dispatcht estate.fn_advisor_review + LATCHT je Alert gegen core.notification_state source=advisor:estate; send=true NUR bei NEUEM Breach) -> Build message (bei send=true die alert.msg-Struktur, gerendert in Owner-Sprache über den geteilten Renderer; sonst Quiet run) -> Anything to report? -> Phrase (model.advisor_review, warm; onError -> deterministischer Text) -> Choose text -> Send (Nudge mit [Erinnerung abschalten] = cron_off:review_register, Roter Faden Paket B). BEGRÜNDETE ABWEICHUNG (Opus-M4): estate hat kein Publish -> die geteilten Advisor-Crons (default-OFF, publish-getriggert) liefen für estate nie -> eigener dünner Cron. Cred estate: Haupt-RW (Latch-Write, Präzedenz cron.advisor_common.ps1).' 360 780

    $stickyEngine = Build-Sticky 'Doc Engine' @(-480, -360) `
        'estate.fn_advisor_review (Registry-Dispatch + Latch, off-canvas)' `
        'estate.fn_advisor_review meldet: (A) Register-Staleness je Erwachsenem (person_records.last_reviewed_at > advisor.estate_review_days=365; fn_confirm_review re-armt), (B) fehlende Vorsorge-Dokumente je Erwachsenem (v_directive_gaps, essential+recommended), (C) finance-Nachlass-Feld-Gaps [Singleton, GUARDED via estate.fn_gap_report doppel-guard -> finance absent = kein Alert, kein Crash). Jeder Alert trägt ein deutsches text-Feld -> der Cron kennt keine estate-Felder, joint nur text; das LLM formuliert um. household -> estate_overview hat KEINE context_scopes-Zeile -> agent.fn_context_persons leer -> person_id NULL (byte-gleich advisor:estate). RAISE-FREI (eine Exception kippt sonst auch den finance-/career-Lauf des geteilten Drift-Crons).' 360 780

    $nodes = @($trig, $gate, $ifEnabled, $off, $tail.LoadNode, $evaluate, $build, $ifReport, $quiet) +
             @($tail.Nodes) + @($send, $stickyOverview, $stickyEngine)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Disabled' )
        ) }
        'Load model config'           = @{ main = @( ,@( E 'Evaluate review' ) ) }
        'Evaluate review'             = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message'               = @{ main = @( ,@( E 'Anything to report?' ) ) }
        'Anything to report?'         = @{ main = @(
            @( E 'Phrase message' ),
            @( E 'Quiet run' )
        ) }
        'Choose text'                 = @{ main = @( ,@( E 'Send review' ) ) }
    }
    foreach ($k in $tail.Connections.Keys) { $conns[$k] = $tail.Connections[$k] }
    return Build-Workflow 'agent.estate.cron_review_register' $nodes $conns
}
