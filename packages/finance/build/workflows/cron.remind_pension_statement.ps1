#Requires -Version 5.1
# Definition agent.finance.cron_remind_pension_statement -> Build-CronRemindPensionStatement. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM, KEIN Write: Renteninformation-Erinnerung (Plan 2026-10-26, Muster cron_reconcile_accounts).
# Schedule -> finance.fn_pension_statements_due() (aktive gesetzliche/betriebliche Renten, deren juengste
# Renteninformation aelter als 13 Monate ist oder die noch keine haben) -> IF count>0 -> EINE Telegram-Nachricht mit
# Anleitung + Knopf [Erinnerung abschalten]. Zeitplan = Platzhalter __CFG_SCHEDULE_REMIND_PENSION_STATEMENT__.
#
# Design wie der Monats-Check: KEIN sendAndWait (die Antwort ist eine Datei; Dateien loesen kein offenes Gate auf). Der
# Nutzer schickt das PDF an den Bot -> agent.finance -> tool_extract_finance_document -> eine Karte.
function Build-CronRemindPensionStatement {
    # Read-only (SELECT + Telegram) -> enge Leserolle finance_ro (D10).
    $CRED_POSTGRES = $CRED_FINANCE_RO

    $trig = Build-ScheduleTrigger @(-680, 0) -ScheduleKey 'remind_pension_statement'

    $gate = Build-Pg 'Cron enabled?' @(-500, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','remind_pension_statement') = 'true', false) AS enabled"
    $gateIf = Build-If 'Cron on?' @(-340, -40) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-340, 160)
    $stickyGate = Build-Sticky 'F9 Cron-Gate (WS4a)' @(-680, -240) `
        'Paket aktiv UND cron_enable.remind_pension_statement' `
        'Erster Schritt: core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''remind_pension_statement'')=''true'' (DB entscheidet, fail-closed). Aus -> No-op. Läuft unter finance_ro (read-only). Toggle: /reminders, der Knopf an der Nachricht oder lifeagents config set cron_enable remind_pension_statement false.' 280 400

    # Eine Zeile: die faelligen Renten (EINE Regel: fn_pension_statements_due nutzt stale/never aus fn_pension_outlook)
    # + die Texte in Owner-Sprache (core.fn_ui_texts_for). Datum per Intl im Owner-Locale in 'Build message'.
    $keys = Get-UiKeysSql (@('finance.dialog.pension_statement_intro', 'finance.dialog.pension_statement_line',
        'finance.dialog.pension_statement_never', 'finance.dialog.pension_statement_howto', 'core.reminders.btn_off') + $script:UiRenderKeys)
    $find = Build-Pg 'Find due pensions' @(-240, 0) @"
=SELECT jsonb_array_length(d) AS due_count, d AS pensions,
       core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys))) AS ui
FROM (SELECT finance.fn_pension_statements_due() AS d) x;
"@ $null

    $ifAny = Build-If 'Any due?' @(0, 0) "={{ `$json.due_count }}" '0' 'larger' 'number'

    $buildJs = (Get-UiRenderLibJs) + @'
const m = $('Find due pensions').first().json;
const U = uiRender(m.ui || {});
const rows = Array.isArray(m.pensions) ? m.pensions : [];
// Person in Klammern, wenn die Rente einer Person gehoert (zwei gleichnamige gesetzliche Renten sonst ununterscheidbar)
const lines = rows.map((r) => U.fill(U.t('finance.dialog.pension_statement_line'), {
  name: r.owner_person_id ? r.name + ' (' + r.owner + ')' : r.name, date: r.last_statement_date ? { kind: 'date', value: r.last_statement_date } : U.t('finance.dialog.pension_statement_never') }));
return [{ json: { message: U.t('finance.dialog.pension_statement_intro') + '\n\n' + lines.join('\n') + '\n\n'
                           + U.t('finance.dialog.pension_statement_howto'),
                  btn_off: U.t('core.reminders.btn_off') } }];
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(220, -100)
        id = (New-Id); name = 'Build message'
    }
    $notify = New-TelegramInlineKeyboardSendNode 'Notify due' @(440, -100) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_off }}'; Data = 'cron_off:remind_pension_statement' } )

    $none = Build-NoOp 'Nothing due' @(220, 120)

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -300) `
        'Renteninformation-Erinnerung (monatlich geprüft, kein LLM, kein Write)' `
        'Schedule (Cron aus core.config schedule.remind_pension_statement, Standard 15 10 5 * *). finance.fn_pension_statements_due() liefert die aktiven gesetzlichen/betrieblichen Renten, deren jüngste Renteninformation älter als 13 Monate ist oder die noch keine haben (dieselbe stale/never-Regel wie das Berater-Fenster fn_pension_outlook). IF count>0 -> Build message (Datum per Intl im Owner-Locale, Anleitung aus dem Katalog) -> EINE Nachricht mit Knopf [Erinnerung abschalten] (cron_off:remind_pension_statement; wieder an in /reminders); sonst No-Op. Monatliche Prüfung: die DRV schickt die Renteninformation zu individuellen Terminen, eine fällige Rente erscheint so spätestens einen Monat nach Ablauf.' 280 560

    $stickyDesign = Build-Sticky 'Workflow danach' @(0, 160) `
        'Ein PDF -> eine Karte -> ein atomarer Write' `
        'Kein sendAndWait hier: die Antwort ist eine Datei, und Dateien/Freitext lösen ein offenes Gate NICHT auf. Der Nutzer schickt die Renteninformation -> agent.finance -> tool_extract_finance_document (Vision: Anspruch, Hochrechnung, 1-%/2-%-Szenario, EM-Rente, Entgeltpunkte, Regelaltersrente) -> fn_import_stage (eine gesetzliche Rente je Person: der Bescheid hängt sich an die vorhandene) -> EINE Karte -> fn_import_bundle schreibt die datierte Zeile in finance.pension_statements (Historie, nie überschrieben).' 260 580

    $nodes = @($trig, $gate, $gateIf, $gateOff, $find, $ifAny, $build, $notify, $none, $stickyOverview, $stickyDesign, $stickyGate)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Find due pensions' ),   # true: Paket aktiv UND Cron an
            @( E 'Disabled' )              # false: aus -> No-op
        ) }
        'Find due pensions'           = @{ main = @( ,@( E 'Any due?' ) ) }
        'Any due?'                    = @{ main = @(
            @( E 'Build message' ),    # true:  count > 0
            @( E 'Nothing due' )       # false: nichts faellig
        ) }
        'Build message'               = @{ main = @( ,@( E 'Notify due' ) ) }
    }
    return (Build-Workflow 'agent.finance.cron_remind_pension_statement' $nodes $conns)
}
